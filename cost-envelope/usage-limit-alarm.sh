# Purpose: get notified when an agent workgroup's daily RPU-hours reach the emit-metric usage limit
#   (serverless-ceilings.sh creates the limit; emit-metric only publishes the metric, so add the alarm).
# Post section: "The cost envelope: predictable by design" (CloudWatch alarm on the usage-limit metric).
# Prerequisites: the emit-metric usage limit on the workgroup; an SNS topic whose policy lets
#   cloudwatch.amazonaws.com publish (aws:SourceAccount = your account), with a subscriber.
# Placeholders: <workgroup-arn>, <agent-workgroup>, <region>, <usage-limit-id>, <limit-rpu-hours> (the limit's
#   amount, for example 150), <sns-topic-arn>.
# Metric notes: Redshift Serverless publishes UsageLimitConsumed and UsageLimitAvailable every 5 minutes per
#   usage limit, as whole RPU-hours (rounded down), with dimensions UsageLimitId, UsageType
#   (SERVERLESS_COMPUTE) and Workgroup. The alarm below goes to ALARM once consumption reaches the limit.

# 1. The usage limit's ID and amount
#    (--usage-type can't be combined with --resource-arn; pick the serverless-compute row)
aws redshift-serverless list-usage-limits --resource-arn <workgroup-arn> \
  --query "usageLimits[?breachAction=='emit-metric'].[usageLimitId,usageType,amount]" \
  --output text --region <region>

# 2. The alarm, with notifications when it fires and when it clears (the limit resets daily)
aws cloudwatch put-metric-alarm --alarm-name <agent-workgroup>-rpu-hours-limit \
  --alarm-description "Daily RPU-hours reached the emit-metric usage limit" \
  --namespace AWS/Redshift-Serverless --metric-name UsageLimitConsumed \
  --dimensions Name=UsageLimitId,Value=<usage-limit-id> Name=UsageType,Value=SERVERLESS_COMPUTE Name=Workgroup,Value=<agent-workgroup> \
  --statistic Maximum --period 300 --evaluation-periods 1 \
  --threshold <limit-rpu-hours> --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions <sns-topic-arn> --ok-actions <sns-topic-arn> --region <region>
aws cloudwatch describe-alarms --alarm-names <agent-workgroup>-rpu-hours-limit --region <region>

# 3. Test the notification path end to end without waiting for the limit
#    (the alarm returns to its real state at the next evaluation)
aws cloudwatch set-alarm-state --alarm-name <agent-workgroup>-rpu-hours-limit \
  --state-value ALARM --state-reason "Testing the notification path" --region <region>
aws cloudwatch describe-alarm-history --alarm-name <agent-workgroup>-rpu-hours-limit \
  --history-item-type Action --region <region>

# Cleanup
aws cloudwatch delete-alarms --alarm-names <agent-workgroup>-rpu-hours-limit --region <region>
