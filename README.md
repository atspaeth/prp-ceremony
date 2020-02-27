This Bash script and associated yml file create a Kubernetes job to run a Jupyter notebook on the PRP cluster and save it back to the local disk. Environment variables can be exported from the shell so the same notebook can be run with different parameter values.

Usage steps:
   1) Set up kubernetes and awscli; make sure both `kubectl get jobs` and `aws s3 ls braingeneers` work.
   1) Create a Jupyter notebook which uses the values of some environment variables through e.g. `os.environ['FISH']`
   1) Export the shell variables you want to use, e.g. `export XYZZY=plover`
   1) Start the notebook on the cluster, passing the variable along with `./prpnb.sh -v XYZZY Advent.ipynb`. Alternately, you can pass literal values for the variables, like `./prpnb.sh -v PANIC=0 Guide.ipynb`.
   1) Go do something else. You can check on the job status with `kubectl get jobs -lnotebook=FooBar.ipynb`.
   1) When the job is completed, run `prpnb.sh` again to download it into your local jobs folder. You can configure this with the environment variable $PRPNB_JOB_DIR; if unset, this defaults to ~/prpnb-jobs. 
   1) Be polite and clean up by deleting completed jobs and the associated configmaps. See which ones this script has created for you by running `kubectl get jobs -luser=$USER` and `kubectl get configmaps -luser=$USER`.

Usage example once everything is set up:
```bash
$ export PARROT=ex
$ prpnb -v PARROT -v SPAM=eggs FooBar.ipynb
upload: ./FooBar.ipynb to s3://braingeneers/atspaeth/jobs/in/20200212-124708-foobar.ipynb
configmap/atspaeth-20200212-124708-foobar-config created
job.batch/atspaeth-20200212-124708-foobar created
configmap/atspaeth-20200212-124708-foobar-config labeled
job.batch/atspaeth-20200212-124708-foobar labeled

$ kubectl get jobs
NAME                              COMPLETIONS   DURATION   AGE
atspaeth-20200212-124708-foobar   1/1           11s        13s

$ prpnb
move: s3://braingeneers/atspaeth/jobs/out/20200212-124708-foobar.ipynb to ./prpnb-jobs/20200212-124708-foobar.ipynb
```

This is basically the same approach as [Rob Currie's](https://github.com/rcurrie/jupyter) Python script, but implemented in Bash because I don't know enough about the boto3 and kubernetes packages and they seemed to be creating some strange issues. 

The script does the following:
  1) Upload the notebook to S3
  1) Create a k8s ConfigMap to hold environment variables.
  1) Create a k8s job referencing that ConfigMap which will run the notebook through nbconvert and put it back on S3.
  1) "Sync": download any output notebooks that have been generated by previous jobs.
  
You will need awscli and kubectl configured with sensible defaults for this to work because the script doesn't support any customization of the calls to those utilities. In particular, awscli should have its default endpoint set (e.g. through [awscli-plugin-endpoint](https://github.com/wbingli/awscli-plugin-endpoint)).

Also, I have no idea how to make Kubernetes clean up after itself, so you have to manually delete the generated configmap and job when everything is finished.
