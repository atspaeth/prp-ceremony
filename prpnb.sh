#!/bin/bash

function die() {
    printf '%s\n' "$1" >&2
    exit 1
}

# Some defaults that are useful to me but not in general :D
: ${BUCKET:=braingeneers}
: ${INTERNAL_ENDPOINT:=rook-ceph-rgw-nautiluss3.rook}
: ${NUM_CORES:=4}

NOTEBOOK=
VARS=('JOB_NAME' 'NUM_CORES' 'USER' 'IN_URL' 'OUT_URL')

while :; do
    case $1 in
        # Help options. 
        -h|-\?|--help)
            show_help
            exit
            ;;

        # Specify the number of cores to run on.
        -c|--cores)
            if [ "$2" ]; then
                NUM_CORES=$2
                shift
            else
                die 'ERR: "--cores" requires a non-empty argument'
            fi
            ;;
        --cores=?*)
            NUM_CORES=${1#*=}
            ;;
        --cores=)
            die 'ERR: "--cores" requires a non-empty argument'
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

        # Standard ones: end of options, and ignoring unknown flags.
        --)
            shift
            break
            ;;
        -?*)
            printf 'WARN: Unknown option (ignored): %s\n' "$1" >&2
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
    TIMESTAMP=
    BASENAME=$(basename $NOTEBOOK .ipynb | tr '[:upper:]' '[:lower:]')
    DATED_NOTEBOOK=$(date +%Y%m%d-%H%M%S)-$BASENAME
    JOB_NAME=$USER-$DATED_NOTEBOOK

    IN_URL="s3://$BUCKET/$USER/jobs/in/$DATED_NOTEBOOK.ipynb"
    OUT_URL="s3://$BUCKET/$USER/jobs/out/$DATED_NOTEBOOK.ipynb"

    # Upload the notebook, then construct a Kubernetes job that knows
    # the appropriate values of the environment variables. 
    aws s3 cp "$NOTEBOOK" "$IN_URL" || exit 1

    # Export all the variables envsubst is going to need.
    LITERALS=()
    for VAR in "${VARS[@]}"; do
        export "$VAR"
        LITERALS+=("--from-literal=$VAR=${!VAR}")
    done

    # Also add a few other environment variables... 
    LITERALS+=("--from-literal=AWS_S3_ENDPOINT=http://$INTERNAL_ENDPOINT")
    LITERALS+=("--from-literal=S3_ENDPOINT=$INTERNAL_ENDPOINT")
    LITERALS+=("--from-literal=OMP_NUM_THREADS=$NUM_CORES")
    LITERALS+=("--from-literal=S3_USE_HTTPS=0")

    kubectl create configmap "$JOB_NAME-config" "${LITERALS[@]}" || exit 1

    # Construct a kubernetes job that will run the notebook based on
    # substituting environment variables into the template. 
    YMLFILE=$(dirname $0)/prpnb.yml
    kubectl apply -f <(envsubst '$JOB_NAME $NUM_CORES' < "$YMLFILE") || exit 1
fi

# Sync any output files that have been produced.
aws s3 sync  "s3://$BUCKET/$USER/jobs/out/" ~/.kube/jobs/
aws s3 rm --recursive "s3://$BUCKET/$USER/jobs/out/"
