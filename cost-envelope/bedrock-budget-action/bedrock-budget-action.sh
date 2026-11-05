# Purpose: one AWS Budgets budget per agent tag for Amazon Bedrock, whose action at 100% attaches a deny
#   policy (bedrock:InvokeModel and bedrock:InvokeModelWithResponseStream) to that agent's model role.
# Post section: "Control model spend per agent" (budget action; policy in the sample repository).
# Prerequisites:
#   - Run in the account that pays for the model calls, as an administrator with IAM and Budgets permissions.
#     Budgets is a global service; call it with --region us-east-1.
#   - <model-role-name> is the IAM role that calls Bedrock. For Redshift ML that is the IAM_ROLE in
#     CREATE EXTERNAL MODEL, not the agent's own role.
#   - The tag filter in bedrock-budget.json counts only spend attributed to IAM principals tagged
#     agent-id=<agent-id>: tag the model role, activate iamPrincipal/agent-id as a cost allocation tag in the
#     management account, and enable caller identity data (see checklist/attribution-to-budget-action.md).
#     Until then the budget tracks $0.
#   - An SNS topic whose policy lets budgets.amazonaws.com publish (for the alert and the action notice).
# Placeholders: <account-id>, <agent-id>, <monthly-usd>, <model-role-name>, <deny-policy-name>,
#   <budget-exec-role-name>, <sns-topic-arn> (in the commands and in the JSON files they reference).
# Budget actions run on billing data, which is updated a few times a day, so spend can pass the
#   threshold before the policy is attached. Treat the action as a period-level brake.

# 1. The deny policy that the action attaches
aws iam create-policy --policy-name <deny-policy-name> \
  --policy-document file://bedrock-budget-action-deny-policy.json

# 2. The execution role that Budgets assumes to attach it (only that policy, only to that role)
aws iam create-role --role-name <budget-exec-role-name> \
  --assume-role-policy-document file://budget-action-execution-role-trust.json
aws iam put-role-policy --role-name <budget-exec-role-name> \
  --policy-name attach-deny-policy-to-model-role \
  --policy-document file://budget-action-execution-role-policy.json

# 3. The budget, with an alert at 80% of actual spend
aws budgets create-budget --account-id <account-id> --budget file://bedrock-budget.json \
  --notifications-with-subscribers file://bedrock-budget-notifications.json --region us-east-1

# 4. The action: at 100% of actual spend, attach the deny policy to the model role, without approval
aws budgets create-budget-action --account-id <account-id> --budget-name <agent-id>-bedrock-monthly \
  --notification-type ACTUAL --action-type APPLY_IAM_POLICY \
  --action-threshold ActionThresholdValue=100,ActionThresholdType=PERCENTAGE \
  --definition file://bedrock-budget-action-definition.json \
  --execution-role-arn arn:aws:iam::<account-id>:role/<budget-exec-role-name> \
  --approval-model AUTOMATIC \
  --subscribers SubscriptionType=SNS,Address=<sns-topic-arn> --region us-east-1

# 5. Check the action (Status STANDBY until the threshold is crossed) and its history
aws budgets describe-budget-actions-for-budget --account-id <account-id> \
  --budget-name <agent-id>-bedrock-monthly --region us-east-1
aws budgets describe-budget-action-histories --account-id <account-id> \
  --budget-name <agent-id>-bedrock-monthly --action-id <action-id> --region us-east-1

# 6. After a decision to restore model access within the period, reverse the action (detaches the policy)
aws budgets execute-budget-action --account-id <account-id> --budget-name <agent-id>-bedrock-monthly \
  --action-id <action-id> --execution-type REVERSE_BUDGET_ACTION --region us-east-1

# Cleanup
aws budgets delete-budget-action --account-id <account-id> --budget-name <agent-id>-bedrock-monthly \
  --action-id <action-id> --region us-east-1
aws budgets delete-budget --account-id <account-id> --budget-name <agent-id>-bedrock-monthly --region us-east-1
aws iam delete-role-policy --role-name <budget-exec-role-name> --policy-name attach-deny-policy-to-model-role
aws iam delete-role --role-name <budget-exec-role-name>
aws iam delete-policy --policy-arn arn:aws:iam::<account-id>:policy/<deny-policy-name>
