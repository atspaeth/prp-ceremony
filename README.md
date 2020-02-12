This Bash script and associated yml file create a Kubernetes job to run a Jupyter notebook on the PRP cluster and save it back to the local disk. Environment variables can be exported from the shell so the same notebook can be run with different parameter values.

Usage steps:
   1) Set up kubernetes and awscli; make sure both `kubectl get jobs` and `aws s3 ls braingeneers` work.
   1) Create a Jupyter notebook which uses the values of some environment variables through e.g. `os.environ['FISH']`
   1) Export the shell variables you want to use, e.g. `export XYZZY=plover`
   1) Start the notebook on the cluster with `./prpnb.sh -v SPAM -v PARROT FooBar.ipynb` (which passes the values of $SPAM and $PARROT from the current environment into the environment of the pod)
   1) Go do something else. You can check on the job status with `kubectl get jobs -lnotebook=FooBar.ipynb`.
   1) When the job is completed, run `prpnb.sh` again to download it into your local jobs folder. You can configure this with the environment variable $PRPNB_JOB_DIR; if unset, this defaults to ~/prpnb-jobs. 
   1) Be polite and clean up by deleting completed jobs and the associated configmaps. See which ones this script has created for you by running `kubectl get jobs -luser=$USER` and `kubectl get configmaps -luser=$USER`.

This is basically the same approach as [Rob Currie's](https://github.com/rcurrie/jupyter) Python script, but implemented in Bash because I don't know enough about the boto3 and kubernetes packages and they seemed to be creating some strange issues. 

The script does the following:
  1) Upload the notebook to S3
  1) Create a k8s ConfigMap to hold environment variables.
  1) Create a k8s job referencing that ConfigMap which will run the notebook through nbconvert and put it back on S3.
  1) "Sync": download any output notebooks that have been generated by previous jobs.
  
You will need awscli and kubectl configured with sensible defaults for this to work because the script doesn't support any customization of the calls to those utilities. In particular, awscli should have its default endpoint set (e.g. through [awscli-plugin-endpoint](https://github.com/wbingli/awscli-plugin-endpoint)).

Also, I have no idea how to make Kubernetes clean up after itself, so you have to manually delete the generated configmap and job when everything is finished.
