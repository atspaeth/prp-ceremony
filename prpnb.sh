#!/bin/bash

function die() {
    printf '%s\n' "$1" >&2
    exit 1
}

function show_help() {
    echo 'usage: prpnb notebook [-b BUCKET] [-v VARIABLE]*'
    echo 
    echo 'Creates a k8s job that executes a Jupyter notebook'
    echo 'Options:'
    echo ' -v the name of a variable to export to the container'
    echo ' -b the name of the s3 bucket for intermediate storage'
}

# Assignment of default values.
: ${BUCKET:=braingeneers}
: ${INTERNAL_ENDPOINT:=rook-ceph-rgw-nautiluss3.rook}

NOTEBOOK=
VARS=(JOB_NAME USER IN_URL OUT_URL OMP_NUM_THREADS \
    AWS_S3_ENDPOINT S3_ENDPOINT S3_USE_HTTPS)

while :; do
    case $1 in
        # Help options. 
        -h|-\?|--help)
            show_help
            exit
            ;;

        # Handle specification of the bucket. You can also provide the
        # BUCKET environment variable to accomplish the same thing.
        -b|--bucket)
            if [ "$2" ]; then
                BUCKET=$2
                shift
            else
                die 'ERR: "--bucket" requires a non-empty argument'
            fi
            ;;
        --bucket=?*)
            BUCKET=${1#*=}
            ;;
        --bucket=)
            die 'ERR: "--bucket" requires a non-empty argument'
            ;;

        # Variables to pass on to the container can be provided on the
        # command line. 
        -v|--variable)
            if [ "$2" ]; then
                VARS+=($2)
                shift
            else
                die 'ERR: "--variable" requires a non-empty argument'
            fi
            ;;
        --variable=?*)
            VARS+=(${1#*=})
            ;;
        --variable=)
            die 'ERR: "--variable" requires a non-empty argument'
            ;;

        # Anything that's not one of these patterns must be a notebook
        # filename; accept the first one, and error on any subsequent
        # ones. Also handle the case where $1 is empty, which means
        # that we've run out of arguments.
        *)
            if [ -z "$1" ]; then
                break
            elif [ -n "$NOTEBOOK" ]; then
                die 'ERR: too many notebooks provided'
            else
                NOTEBOOK=$1
            fi
            ;;
    esac
    shift
done

# If a notebook was provided, run it. Otherwise, just sync.
if [ -n "$NOTEBOOK" ]; then

    # You can't name things after a notebook that has uppercase
    # letters for some reason.
    BASENAME=$(basename $NOTEBOOK .ipynb | tr '[:upper:]' '[:lower:]')
    DATED_NOTEBOOK=$(date +%Y%m%d-%H%M%S)-$BASENAME
    export JOB_NAME=$USER-$DATED_NOTEBOOK

    IN_URL="s3://$BUCKET/$USER/jobs/in/$DATED_NOTEBOOK.ipynb"
    OUT_URL="s3://$BUCKET/$USER/jobs/out/$DATED_NOTEBOOK.ipynb"

    # Upload the notebook, then construct a Kubernetes job that knows
    # the appropriate values of the environment variables. 
    aws s3 cp "$NOTEBOOK" "$IN_URL" || exit 1

    # Create a list of variables to construct the configmap.
    AWS_S3_ENDPOINT=http://$INTERNAL_ENDPOINT
    S3_ENDPOINT=$INTERNAL_ENDPOINT
    S3_USE_HTTPS=0
    OMP_NUM_THREADS=1
    LITERALS=()
    for VAR in "${VARS[@]}"; do
        LITERALS+=("--from-literal=$VAR=${!VAR}")
    done

    kubectl create configmap "$JOB_NAME-config" "${LITERALS[@]}" || exit 1

    # Construct a kubernetes job that will run the notebook based on
    # substituting environment variables into the template. 
    YMLFILE=$(dirname $0)/prpnb.yml
    kubectl apply -f <(envsubst '$JOB_NAME' < "$YMLFILE") || exit 1

    # Attach labels to the job and configmap so I can filter on them.
    LABELS=("user=$USER" "notebook=$(basename $NOTEBOOK)" )
    kubectl label configmap "$JOB_NAME-config" "${LABELS[@]}" || exit 1
    kubectl label job "$JOB_NAME" "${LABELS[@]}" || exit 1
fi

# Sync any output files that have been produced.
aws s3 sync  "s3://$BUCKET/$USER/jobs/out/" ~/.kube/jobs/
aws s3 rm --recursive "s3://$BUCKET/$USER/jobs/out/"
