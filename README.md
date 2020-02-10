This Bash script and associated yml file create a Kubernetes job to run a Jupyter notebook on the PRP cluster and save it back to the local disk. Environment variables can be exported from the shell so the same notebook can be run with different parameter values.

This is basically the same approach as [Rob Currie's](https://github.com/rcurrie/jupyter) Python script, but implemented in Bash because I don't know enough about the boto3 and kubernetes packages and they seemed to be creating some strange issues. 

On a high level, the steps are:
  1) Upload the notebook to S3
  1) Create a k8s ConfigMap to hold environment variables.
  1) Create a k8s job referencing that ConfigMap which will run the notebook through nbconvert and put it back on S3.
  1) "Sync": download any output notebooks that have been generated by previous jobs.
  
You will need awscli and kubectl configured with sensible defaults for this to work because the script doesn't support any customization of the calls to those utilities. In particular, awscli should have its default endpoint set (e.g. through [awscli-plugin-endpoint](https://github.com/wbingli/awscli-plugin-endpoint)).