#!/bin/bash

function die() {
    printf '%s\n' "$1" >&2
    exit 1
}

function show_help() {
    echo "usage: prpnb [-p PROFILE] [notebook] [-v VARIABLE]*

Creates a k8s job that executes a Jupyter notebook

Options:
 -h   Show this message and exit.
 -p   Specify the awscli profile to use
 -v   Provide the name of a variable to export to the container,
      or an expression (e.g. SPAM=eggs) to be exported.

If a notebook is provided, it will be run on the PRP. Otherwise, the
notebook output directory will be checked for completed jobs, and any
output notebooks will be downloaded.
"
}

# Assignment of default values.
: ${PRPNB_INTERNAL_ENDPOINT:=rook-ceph-rgw-nautiluss3.rook}
: ${PRPNB_JOB_DIR:=~/prpnb-jobs}
: ${PRPNB_AWSCLI_PROFILE:=prpnb}

NOTEBOOK=
VARS=(JOB_NAME USER IN_URL OUT_URL OMP_NUM_THREADS \
    AWS_S3_ENDPOINT S3_ENDPOINT S3_USE_HTTPS)

function parse_assignment() {
    if [ -n "$1" ]; then
        export "$1"
        VARS+=(${1%%=*})
    else
        die 'ERR: "--variable" requires a non-empty argument'
    fi
}

while :; do
    case $1 in
        # Help options.
        -h|-\?|--help)
            show_help
            exit
            ;;

        # Select an awscli profile so people can use both PRP and
        # actual Amazon S3 without weird config juggling.
        -p|--profile)
            shift
            PRPNB_AWSCLI_PROFILE=$2
            ;;
        --profile=*)
            PRPNB_AWSCLI_PROFILE="${1#--profile=}"
            ;;
        -p*)
            PRPNB_AWSCLI_PROFILE="${1#-p}"
            ;;

        # Also accept an endpoint argument and pass it to awscli.
        --endpoint)
            shift
            ENDPOINT_ARG="--endpoint=$1"
            ;;
        --endpoint=*)
            ENDPOINT_ARG=$1
            ;;

        # Activate test mode.
        --test)
            activate_test_mode=yep
            ;;

        # Variables to pass on to the container can be provided on the
        # command line. You can also set their values directly in the
        # command line with the syntax -v SPAM=eggs
        -v)
            shift
            parse_assignment "$1"
            ;;
        -v*)
            parse_assignment "${1#-v}"
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

PRPNB_AWS_ARGS=(--profile="$PRPNB_AWSCLI_PROFILE")
if [ -n "$ENDPOINT_ARG" ]; then
    AWS_ARGS+=("$ENDPOINT_ARG")
fi

function aws () {
    command aws "${AWS_ARGS[@]}" "$@"
}

if [ xyep == x"$activate_test_mode" ]; then
    aws s3 ls s3://braingeneers/ || exit 1

    kubectl get jobs || exit 1

    if [ -n "$NOTEBOOK" ]; then
        echo Would now upload "$NOTEBOOK"
    fi

    exit 0
fi

# If a notebook was provided, run it. Otherwise, just sync.
if [ -n "$NOTEBOOK" ]; then

    # You can't name things after a notebook that has uppercase
    # letters for some reason.
    BASENAME=$(basename $NOTEBOOK .ipynb | tr '[:upper:]' '[:lower:]')
    DATED_NOTEBOOK=$(date +%Y%m%d-%H%M%S)-$BASENAME
    export JOB_NAME=$USER-$DATED_NOTEBOOK

    IN_URL="s3://braingeneers/$USER/jobs/in/$DATED_NOTEBOOK.ipynb"
    OUT_URL="s3://braingeneers/$USER/jobs/out/$DATED_NOTEBOOK.ipynb"

    # Upload the notebook to s3 where the job can get it.
    aws s3 cp "$NOTEBOOK" "$IN_URL" || exit 1

    # Create a list of variables to construct the configmap.
    AWS_S3_ENDPOINT=http://$PRPNB_INTERNAL_ENDPOINT
    S3_ENDPOINT=$PRPNB_INTERNAL_ENDPOINT
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
    LABELS=("user=$USER" "notebook=$(basename $NOTEBOOK)" prpnb=prpnb)
    kubectl label configmap "$JOB_NAME-config" "${LABELS[@]}" || exit 1
    kubectl label job "$JOB_NAME" "${LABELS[@]}" || exit 1
fi

# Sync completed remote notebooks down to the local job directory.
aws s3 mv --recursive "s3://braingeneers/$USER/jobs/out/" "$PRPNB_JOB_DIR"

# Finally, delete all the completed jobs and their configmaps.
COMPLETED=($(kubectl get jobs -lprpnb=prpnb -luser="$USER" \
    "-o=jsonpath={.items[?(@.status.succeeded==1)].metadata.name}"))
for JOB in "${COMPLETED[@]}"; do
    kubectl delete job "$JOB"
    kubectl delete configmap "$JOB"-config
done

