# Workload ceiling: at most 128 RPUs. Assumes a base capacity below that, such as 32; the default base is 128
aws redshift-serverless update-workgroup --workgroup-name agents-wg --max-capacity 128
 
# Emit a metric for an alarm at 150 RPU-hours a day; turn off user queries at 200
aws redshift-serverless create-usage-limit \
  --resource-arn arn:aws:redshift-serverless:us-east-1:111122223333:workgroup/<workgroup-id> \
  --usage-type serverless-compute --period daily --amount 150 --breach-action emit-metric
aws redshift-serverless create-usage-limit \
  --resource-arn arn:aws:redshift-serverless:us-east-1:111122223333:workgroup/<workgroup-id> \
  --usage-type serverless-compute --period daily --amount 200 --breach-action deactivate
