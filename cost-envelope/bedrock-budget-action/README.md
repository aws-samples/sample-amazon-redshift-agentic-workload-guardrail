# Bedrock budget action: cap model spend per agent

One AWS Budgets budget per agent tag tracks that agent's Amazon Bedrock spend, alerts at 80%, and at 100% attaches a deny policy to the agent's model role, so that one role stops calling models until the period ends or someone reverses the action. The commands are in `bedrock-budget-action.sh`, and the six JSON files hold the policies, the budget and the action definition it references.
In the accompanying blog post: section "Control model spend per agent".

## When to use it

When an agent, or a Redshift ML tool, calls Bedrock models under its own IAM role and you want a spend cap per agent rather than per account. It addresses unbounded consumption. It's a period-level brake, not a real-time stop: budget actions run on billing data, which is updated a few times a day, so spend can pass the threshold before the policy is attached. Test the whole chain first with the [attribution-to-budget-action checklist](../../checklist/attribution-to-budget-action.md).

## Who runs it

- An administrator with IAM and AWS Budgets permissions in the account that pays for the model calls.
- A management-account (payer) administrator, for the cost allocation tag and caller identity data.

## Prerequisites

- The IAM role that calls Bedrock (`<model-role-name>`), tagged `agent-id=<agent-id>`. For Redshift ML that is the `IAM_ROLE` in `CREATE EXTERNAL MODEL`, not the agent's own role.
- In the management account: `iamPrincipal/agent-id` activated as a cost allocation tag, and IAM principal (caller identity) data turned on. See [Using IAM principal for cost allocation](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/iam-principal-cost-allocation.html) and [Activating user-defined cost allocation tags](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/activating-tags.html) in the AWS Billing User Guide. Until then the budget tracks $0.
- An Amazon SNS topic whose access policy lets `budgets.amazonaws.com` publish, for the 80% alert and the action notice. See [Creating an Amazon SNS topic for budget notifications](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-sns-policy.html).
- The end-to-end test in [`../../checklist/attribution-to-budget-action.md`](../../checklist/attribution-to-budget-action.md), before you rely on the action.

Placeholders, in the commands and in the JSON files they reference:
- `<account-id>`: the account that pays for the model calls (in the commands, `bedrock-budget-action-definition.json`, `budget-action-execution-role-policy.json` and `budget-action-execution-role-trust.json`).
- `<agent-id>`: the agent's tag value; it also names the budget `<agent-id>-bedrock-monthly` (in the commands and `bedrock-budget.json`).
- `<monthly-usd>`: the monthly budget in US dollars (`bedrock-budget.json`).
- `<model-role-name>`: the IAM role that calls Bedrock (`bedrock-budget-action-definition.json`, `budget-action-execution-role-policy.json`).
- `<deny-policy-name>`: the name you give the deny policy (in the commands, `bedrock-budget-action-definition.json`, `budget-action-execution-role-policy.json`).
- `<budget-exec-role-name>`: the name you give the execution role that AWS Budgets assumes.
- `<sns-topic-arn>`: the topic for the alert and the action notice (in the commands and `bedrock-budget-notifications.json`).
- `<action-id>`: the ID that `create-budget-action` returns, used in Verify, Restore and Clean up.

## How it works

The budget counts only Bedrock spend attributed to IAM principals tagged `agent-id=<agent-id>`, and notifies the SNS topic at 80% of actual spend. At 100% of actual spend, the budget action uses the execution role to attach the deny policy to the model role, without approval. The execution role can attach and detach only that policy, only on that role. See the "Budget per agent" box in the [cost envelope diagram](../README.md) and [Configuring budget actions](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-controls.html) in the AWS Cost Management User Guide.

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`bedrock-budget-action.sh`](bedrock-budget-action.sh) | AWS CLI lines in numbered blocks: create the deny policy, the execution role, the budget and the action (`# 1.` to `# 4.`), check it (`# 5.`), reverse it (`# 6.`), and clean up. Quoted below, never run as a script | Set up, Verify, Clean up | run as an administrator in the paying account |
| [`bedrock-budget-action-deny-policy.json`](bedrock-budget-action-deny-policy.json) | IAM policy that denies `bedrock:InvokeModel` and `bedrock:InvokeModelWithResponseStream`. Placeholders: none | Step 1, `create-policy` | attached to the model IAM role by the budget action |
| [`budget-action-execution-role-trust.json`](budget-action-execution-role-trust.json) | Trust policy that lets `budgets.amazonaws.com` assume the execution role, only from your account (`aws:SourceAccount`) | Step 2, `create-role` | trust policy of the execution role |
| [`budget-action-execution-role-policy.json`](budget-action-execution-role-policy.json) | IAM policy that allows `iam:AttachRolePolicy` and `iam:DetachRolePolicy` only on the model role, only for the deny policy | Step 2, `put-role-policy` (inline policy `attach-deny-policy-to-model-role`) | attached to the execution role |
| [`bedrock-budget.json`](bedrock-budget.json) | The monthly cost budget `<agent-id>-bedrock-monthly`, filtered to Service = Amazon Bedrock and the tag `iamPrincipal/agent-id` = `<agent-id>` | Step 3, `create-budget --budget` | none (budget definition) |
| [`bedrock-budget-notifications.json`](bedrock-budget-notifications.json) | One notification: actual spend above 80%, to the SNS topic | Step 3, `create-budget --notifications-with-subscribers` | none (budget definition) |
| [`bedrock-budget-action-definition.json`](bedrock-budget-action-definition.json) | Which policy the action attaches (`<deny-policy-name>`) to which role (`<model-role-name>`) | Step 4, `create-budget-action --definition` | none (action definition) |

## Set up

Replace the placeholders in the copied lines first, and in the JSON files they reference. Don't run the `.sh` file with `bash`: it ends with lines that reverse and delete what the earlier lines create. AWS Budgets is a global service; the commands call it with `--region us-east-1`.

### 1. Create the deny policy

Lines under `# 1.` of `bedrock-budget-action.sh`, quoted as written:

```bash
cd cost-envelope/bedrock-budget-action
# 1. The deny policy that the action attaches
aws iam create-policy --policy-name <deny-policy-name> \
  --policy-document file://bedrock-budget-action-deny-policy.json
```

What this does:
- Creates the customer managed policy `<deny-policy-name>`. Nothing is attached yet.

### 2. Create the execution role

Lines under `# 2.` of `bedrock-budget-action.sh`, quoted as written:

```bash
cd cost-envelope/bedrock-budget-action
# 2. The execution role that Budgets assumes to attach it (only that policy, only to that role)
aws iam create-role --role-name <budget-exec-role-name> \
  --assume-role-policy-document file://budget-action-execution-role-trust.json
aws iam put-role-policy --role-name <budget-exec-role-name> \
  --policy-name attach-deny-policy-to-model-role \
  --policy-document file://budget-action-execution-role-policy.json
```

What this does:
- Creates the role `<budget-exec-role-name>`, which only AWS Budgets in your account can assume.
- Adds the inline policy `attach-deny-policy-to-model-role`: attach or detach the deny policy, on the model role only.

### 3. Create the budget

Lines under `# 3.` of `bedrock-budget-action.sh`, quoted as written:

```bash
cd cost-envelope/bedrock-budget-action
# 3. The budget, with an alert at 80% of actual spend
aws budgets create-budget --account-id <account-id> --budget file://bedrock-budget.json \
  --notifications-with-subscribers file://bedrock-budget-notifications.json --region us-east-1
```

What this does:
- Creates the monthly budget `<agent-id>-bedrock-monthly` for Bedrock spend by principals tagged `agent-id=<agent-id>`, with an alert at 80% of actual spend.

### 4. Create the budget action

Lines under `# 4.` of `bedrock-budget-action.sh`, quoted as written:

```bash
cd cost-envelope/bedrock-budget-action
# 4. The action: at 100% of actual spend, attach the deny policy to the model role, without approval
aws budgets create-budget-action --account-id <account-id> --budget-name <agent-id>-bedrock-monthly \
  --notification-type ACTUAL --action-type APPLY_IAM_POLICY \
  --action-threshold ActionThresholdValue=100,ActionThresholdType=PERCENTAGE \
  --definition file://bedrock-budget-action-definition.json \
  --execution-role-arn arn:aws:iam::<account-id>:role/<budget-exec-role-name> \
  --approval-model AUTOMATIC \
  --subscribers SubscriptionType=SNS,Address=<sns-topic-arn> --region us-east-1
```

What this does:
- Creates the action. It returns an `ActionId`; use it as `<action-id>` below.
- With `--approval-model AUTOMATIC` the policy is attached as soon as actual spend reaches 100%. With `--approval-model MANUAL` the action waits until someone approves it; use it for agents where an automatic stop is worse than the overspend.

## Verify

Lines under `# 5.` of `bedrock-budget-action.sh`, quoted as written:

```bash
cd cost-envelope/bedrock-budget-action
# 5. Check the action (Status STANDBY until the threshold is crossed) and its history
aws budgets describe-budget-actions-for-budget --account-id <account-id> \
  --budget-name <agent-id>-bedrock-monthly --region us-east-1
aws budgets describe-budget-action-histories --account-id <account-id> \
  --budget-name <agent-id>-bedrock-monthly --action-id <action-id> --region us-east-1
```

| Check | Run as | Expected result |
| --- | --- | --- |
| `describe-budget-actions-for-budget` | administrator | the action with `Status` `STANDBY` until the threshold is crossed |
| A model call by the model role while the deny policy is attached (attach it by hand, or let a test budget fire) | the model role, for example through Redshift ML | `Error sent from Bedrock: User: arn:aws:sts::<account-id>:assumed-role/<model-role-name>/RedshiftIamRoleSession is not authorized to perform: bedrock:InvokeModel` |
| `describe-budget-action-histories` after the action ran | administrator | an `EXECUTION_SUCCESS` entry |

### Restore model access in the same period

After a decision to give the agent its model access back before the period ends, reverse the action. Lines under `# 6.` of `bedrock-budget-action.sh`, quoted as written:

```bash
cd cost-envelope/bedrock-budget-action
# 6. After a decision to restore model access within the period, reverse the action (detaches the policy)
aws budgets execute-budget-action --account-id <account-id> --budget-name <agent-id>-bedrock-monthly \
  --action-id <action-id> --execution-type REVERSE_BUDGET_ACTION --region us-east-1
```

Expected result: the deny policy is detached from the model role, and `describe-budget-action-histories` shows `REVERSE_SUCCESS`. Detaching the policy by hand leaves the action in `EXECUTION_SUCCESS`, so use the reverse command to keep the budget's history accurate.

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| The budget tracks $0 while the agent calls models | The `iamPrincipal/agent-id` tag isn't active as a cost allocation tag yet, or caller identity data is off. Tags appear for activation only after the tagged role has called Bedrock, and activation can take up to 24 hours | Finish steps 2 and 3 of the [checklist](../../checklist/attribution-to-budget-action.md). To check the firing path before then, use a test budget filtered only on Service = Amazon Bedrock |
| The action never fires in a test | Billing data is updated a few times a day, so a new budget can take hours to reach the threshold | Use a test budget whose limit is already exceeded (for example Service = Amazon Bedrock, annual, $0.01); it fires at its first evaluation |
| The model call still succeeds after the action ran | The action attached the policy to another role than the one that calls Bedrock | Put the role that calls Bedrock in `bedrock-budget-action-definition.json`; for Redshift ML, the `IAM_ROLE` of `CREATE EXTERNAL MODEL` |

## Clean up

If the action ran and you haven't reversed it, run the block from [Restore model access in the same period](#restore-model-access-in-the-same-period) first. Then the five lines under `# Cleanup` of `bedrock-budget-action.sh`, quoted as written:

```bash
cd cost-envelope/bedrock-budget-action
aws budgets delete-budget-action --account-id <account-id> --budget-name <agent-id>-bedrock-monthly \
  --action-id <action-id> --region us-east-1
aws budgets delete-budget --account-id <account-id> --budget-name <agent-id>-bedrock-monthly --region us-east-1
aws iam delete-role-policy --role-name <budget-exec-role-name> --policy-name attach-deny-policy-to-model-role
aws iam delete-role --role-name <budget-exec-role-name>
aws iam delete-policy --policy-arn arn:aws:iam::<account-id>:policy/<deny-policy-name>
```

## Used by

- [`../../checklist/attribution-to-budget-action.md`](../../checklist/attribution-to-budget-action.md): the end-to-end test of this kit.
- [`../../observe/cost-ledger/`](../../observe/cost-ledger/README.md): `bedrock-tokens-cur2.sql` shows the spend per role and agent tag that this budget acts on.
- Any access path whose agent calls Bedrock under its own role, for example the [AgentCore custom agent](../../access-layer/agentcore-custom-agent/).
