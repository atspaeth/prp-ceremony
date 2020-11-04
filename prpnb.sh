#!/bin/bash

cd $(dirname $0) && echo -n 'Git: ' && git pull || exit 1

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

function aws () {
    command aws "${aws_args[@]}" "$@"
}

# Default values and parameters.
S3_ENDPOINT=${PRPNB_INTERNAL_ENDPOINT:-rook-ceph-rgw-nautiluss3.rook}
job_dir=${PRPNB_JOB_DIR:-~/prpnb-jobs}
profile=${PRPNB_AWSCLI_PROFILE:-prpnb}
s3_base_dir="s3://braingeneers/personal/$USER/jobs"
notebook=
aws_args=()
vars=(JOB_NAME USER IN_URL OUT_URL OMP_NUM_THREADS \
    AWS_S3_ENDPOINT S3_ENDPOINT S3_USE_HTTPS)

function parse_assignment() {
    if [ -n "$1" ]; then
        export "$1"
        vars+=(${1%%=*})
    else
        die 'ERR: "--variable" requires a non-empty argument'
    fi
}

if [ -z "$USER" ]; then
    die 'ERR: you need to provide a username in the variable $USER.'
fi

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
            profile="$1"
            ;;
        --profile=*)
            profile="${1#--profile=}"
            ;;
        -p*)
            profile="${1#-p}"
            ;;

        # Also accept an endpoint argument and pass it to awscli.
        --endpoint)
            shift
            endpoint="$1"
            ;;
        --endpoint=*)
            endpoint="${1#--endpoint=}"
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
            elif [ -n "$notebook" ]; then
                die 'ERR: too many notebooks provided'
            else
                notebook=$1
            fi
            ;;
    esac
    shift
done

if [ -n "$endpoint" ]; then aws_args+=(--endpoint="$endpoint"); fi
if [ -n "$profile" ]; then aws_args+=(--profile="$profile"); fi

# If a notebook was provided, run it. Otherwise, just sync.
if [ -n "$notebook" ]; then

    # You can't name things after a notebook that has uppercase
    # letters for some reason.
    basename=$(basename $notebook .ipynb | tr '[:upper:]' '[:lower:]')
    dated_notebook=$(date +%Y%m%d-%H%M%S)-$basename
    export JOB_NAME=$USER-$dated_notebook

    IN_URL="$s3_base_dir/in/$dated_notebook.ipynb"
    OUT_URL="$s3_base_dir/out/$dated_notebook.ipynb"

    # Upload the notebook to s3 where the job can get it.
    aws s3 cp "$notebook" "$IN_URL" || exit 1

    # Create a list of variables to construct the configmap.
    AWS_S3_ENDPOINT="http://$S3_ENDPOINT"
    S3_USE_HTTPS=0
    OMP_NUM_THREADS=1
    literals=()
    for var in "${vars[@]}"; do
        literals+=("--from-literal=$var=${!var}")
    done

    kubectl create configmap "$JOB_NAME-config" "${literals[@]}" || exit 1

    # Construct a kubernetes job that will run the notebook based on
    # substituting environment variables into the template.
    ymlfile=$(dirname $0)/prpnb.yml
    kubectl apply -f <(envsubst '$JOB_NAME' < "$ymlfile") || exit 1

    # Attach labels to the job and configmap so I can filter on them.
    labels=("user=$USER" "notebook=$(basename $notebook)" prpnb=prpnb)
    kubectl label configmap "$JOB_NAME-config" "${labels[@]}" || exit 1
    kubectl label job "$JOB_NAME" "${labels[@]}" || exit 1
fi

# Sync completed remote notebooks down to the local job directory.
aws s3 mv --recursive "$s3_base_dir/out/" "$job_dir"

# Finally, delete all the completed jobs and their configmaps.
completed=($(command kubectl get jobs -lprpnb=prpnb -luser="$USER" \
    "-o=jsonpath={.items[?(@.status.succeeded==1)].metadata.name}"))
for job in "${completed[@]}"; do
    kubectl delete job "$job"
    kubectl delete configmap "$job"-config
done

