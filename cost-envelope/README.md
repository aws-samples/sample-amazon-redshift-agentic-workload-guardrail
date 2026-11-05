# Cost envelope: keep agent spend predictable

An agent can retry, loop or ask for more than it needs, and each call costs Redshift compute or model tokens. The cost envelope puts limits around every agent query and model call, from one statement up to a daily total for the workgroup, so spend stays inside a ceiling you chose. It addresses unbounded consumption.
In the accompanying blog post: sections "The cost envelope: predictable by design", "Spend less per answer", "Store less: compress columns and Iceberg files" and "Control model spend per agent".

![Nested boxes showing the cost envelope, from outer to inner: per account (AWS Budgets alerts and AWS Cost Anomaly Detection), per Bedrock principal (cost by IAM principal in CUR 2.0 with activated agent tags, and a budget action that denies the agent's Bedrock calls), per period (usage limits on RPU-hours), per workload (a dedicated workgroup or queue with max capacity), per query (query limits and statement_timeout), and per LLM call (a trusted tool fixes maxTokens, input size, and row count; approved models only). The outer two act on billing data and the inner ones in real time. A band lists the three ceilings to set on day one.](../images/fig6-cost-envelope.png)

The figure above is the concept. The one below shows which file in this folder sets each limit.

![Nested Redshift limits for agent queries, from the outside in: a daily usage limit that alarms at 150 RPU-hours and stops user queries at 200, a max capacity of 128 RPUs, per-user connection limits and session timeouts, and a per-statement timeout of 120 seconds, each labeled with the file that sets it. Beside them, model spend controls: a bounded model call, inference once per row, and a per-agent budget that alerts at 80 percent and denies model calls at 100 percent.](../images/cost-envelope-limits.png)

## Groups

| Group | What it controls | Run as | Files |
| --- | --- | --- | --- |
| [Serverless ceilings and the usage-limit alarm](#serverless-ceilings-and-the-usage-limit-alarm) | Max capacity of the agent workgroup, two daily RPU-hour usage limits, and an alarm on the first one | Redshift and CloudWatch administrator | `serverless-ceilings.sh`, `usage-limit-alarm.sh` |
| [Per-user limits and the model tool identity](#per-user-limits-and-the-model-tool-identity) | `statement_timeout`, `CONNECTION LIMIT` and `SESSION TIMEOUT` per agent user, and a separate identity that alone can call the model, with bounded input, rows and output | Database administrator | `model-spend-summarizer.sql` |
| [Redshift ML precompute](#redshift-ml-precompute) | Model calls only for rows without a stored result | Administrator, then the view owner and the tool identity | `precompute-prompts.sql` |
| Model spend per agent (Bedrock budget action) | A budget per agent tag whose action denies model calls at 100% | Account or FinOps administrator | [bedrock-budget-action/](bedrock-budget-action/README.md) |
| [Storage compression](#storage-compression) | The Iceberg compression codec, and estimated savings on managed storage | Database administrator | `storage-compression.sql` |
| [Configured outside this repository](#configured-outside-this-repository) | Account budgets, anomaly detection, query limits and queues | FinOps or Redshift administrator | none |

Set up the two Redshift ML groups in this order, because each file needs an object the other creates: `model-spend-summarizer.sql` grants `EXECUTE` on the model that precompute part 1 creates, and part 1 grants to `support_summary_tool`, which `model-spend-summarizer.sql` creates.

1. Lines 1 to 5 of [`model-spend-summarizer.sql`](model-spend-summarizer.sql): `support_summary_tool` and its grants on `support.tickets`.
2. Part 1 of [`precompute-prompts.sql`](precompute-prompts.sql): the model `support.ticket_summary`, the prompts view, the results table and the tool's grants.
3. Lines 6 to 14 of `model-spend-summarizer.sql`: `EXECUTE` on the model, the `ASSUMEROLE` grant-back, the summarizer's role grant and the per-user limits.

If you bring your own model instead of precompute part 1, create it first and run lines 1 to 14 of `model-spend-summarizer.sql` in one go.

Clean up in this order: Redshift ML precompute, Per-user limits and the model tool identity, Serverless ceilings and the usage-limit alarm, then the Bedrock budget action subfolder.

The SQL in this README runs in database `dev`. Run each command block from the repository root; each one starts with the `cd` it needs.

## Serverless ceilings and the usage-limit alarm

### When to use it

On every agent workgroup, from day one. Max capacity caps the RPUs the workgroup uses at any moment; a usage limit acts on the RPU-hours used per period. An `emit-metric` usage limit only publishes a metric, so add the alarm to hear about it before the `deactivate` limit turns off user queries. It addresses unbounded consumption.

### Who runs it

An administrator with Redshift Serverless and CloudWatch permissions, outside any agent.

### Prerequisites

- A Redshift Serverless workgroup for agents whose base capacity is below 128 RPUs, such as 32 (the default base capacity is 128).
- For the alarm: an Amazon SNS topic whose access policy lets `cloudwatch.amazonaws.com` publish (with `aws:SourceAccount` set to your account), with a subscriber. See [Notifying users on alarm changes](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Notify_Users_Alarm_Changes.html) in the Amazon CloudWatch User Guide.

Placeholders:
- `agents-wg`: the example workgroup name in `serverless-ceilings.sh`.
- `<workgroup-id>`: the workgroup's ID, in the usage limit ARNs. `111122223333` and `us-east-1` in the same ARNs are the example account and Region.
- `<workgroup-arn>`: the workgroup's ARN.
- `<agent-workgroup>`: the workgroup name, used in the alarm name and dimensions.
- `<region>`: the workgroup's Region.
- `<usage-limit-id>`: the ID of the `emit-metric` usage limit (step 2 lists it).
- `<limit-rpu-hours>`: that limit's amount, for example `150`.
- `<sns-topic-arn>`: the topic that receives the alarm notifications.
- `<previous-value>`: the max capacity you record in step 0.

### How it works

This group is the "Daily usage limit" and "Max capacity" bands of the second diagram above. Redshift Serverless publishes `UsageLimitConsumed` for each usage limit every 5 minutes, as whole RPU-hours; the alarm goes to ALARM once consumption reaches the limit's amount. See [Setting usage limits, including setting RPU limits](https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-workgroup-max-rpu.html) in the Amazon Redshift Management Guide.

### Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`serverless-ceilings.sh`](serverless-ceilings.sh) | AWS CLI lines: max capacity 128 RPUs, and two daily usage limits (emit a metric at 150 RPU-hours, turn off user queries at 200). Quoted below, never run as a script | Set up step 1 | run as a Redshift administrator |
| [`usage-limit-alarm.sh`](usage-limit-alarm.sh) | AWS CLI lines: find the `emit-metric` limit, create the CloudWatch alarm with SNS notifications, test the notification path, and delete the alarm. Quoted below, never run as a script | Set up step 2, Verify, Clean up | run as a CloudWatch administrator |

### Set up

#### 0. Record the current max capacity

So cleanup can restore it:

```bash
cd cost-envelope
aws redshift-serverless get-workgroup --workgroup-name agents-wg --query workgroup.maxCapacity
```

#### 1. Set the ceilings

All three commands of `serverless-ceilings.sh`, quoted as written; replace `agents-wg`, `111122223333`, `us-east-1` and `<workgroup-id>` after you copy the lines:

```bash
cd cost-envelope
# Workload ceiling: at most 128 RPUs. Assumes a base capacity below that, such as 32; the default base is 128
aws redshift-serverless update-workgroup --workgroup-name agents-wg --max-capacity 128
# Emit a metric for an alarm at 150 RPU-hours a day; turn off user queries at 200
aws redshift-serverless create-usage-limit \
  --resource-arn arn:aws:redshift-serverless:us-east-1:111122223333:workgroup/<workgroup-id> \
  --usage-type serverless-compute --period daily --amount 150 --breach-action emit-metric
aws redshift-serverless create-usage-limit \
  --resource-arn arn:aws:redshift-serverless:us-east-1:111122223333:workgroup/<workgroup-id> \
  --usage-type serverless-compute --period daily --amount 200 --breach-action deactivate
```

What this does:
- Caps the workgroup at 128 RPUs at any moment.
- Creates two daily limits on RPU-hours: at 150 Redshift publishes a metric; at 200 it turns off user queries until the next period.

#### 2. Add the alarm

Steps `# 1.` and `# 2.` of `usage-limit-alarm.sh`, quoted as written; replace the placeholders after you copy the lines. Run the first command, put the ID it returns in `<usage-limit-id>`, then run the rest:

```bash
cd cost-envelope
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
```

What this does:
- Creates the alarm `<agent-workgroup>-rpu-hours-limit` on `UsageLimitConsumed`, which notifies the topic when it fires and when it clears.
- `describe-alarms` shows the topic in `AlarmActions`.

### Verify

Test the notification path without waiting for the limit. Step `# 3.` of `usage-limit-alarm.sh`, quoted as written:

```bash
cd cost-envelope
# 3. Test the notification path end to end without waiting for the limit
#    (the alarm returns to its real state at the next evaluation)
aws cloudwatch set-alarm-state --alarm-name <agent-workgroup>-rpu-hours-limit \
  --state-value ALARM --state-reason "Testing the notification path" --region <region>
aws cloudwatch describe-alarm-history --alarm-name <agent-workgroup>-rpu-hours-limit \
  --history-item-type Action --region <region>
```

Then list the workgroup's usage limits and its max capacity:

```bash
cd cost-envelope
aws redshift-serverless list-usage-limits --resource-arn <workgroup-arn> \
  --query "usageLimits[].[usageLimitId,period,amount,breachAction]" --output table
aws redshift-serverless get-workgroup --workgroup-name agents-wg --query workgroup.maxCapacity
```

| Check | Run as | Expected result |
| --- | --- | --- |
| `describe-alarm-history` after `set-alarm-state` | CloudWatch administrator | an Action item "Successfully executed action arn:aws:sns:...", and a message on the topic |
| `list-usage-limits` | Redshift administrator | two `daily` rows: amount 150 with `emit-metric`, amount 200 with `deactivate` |
| `get-workgroup ... maxCapacity` | Redshift administrator | `128` |

### Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `list-usage-limits` fails when you pass both `--usage-type` and `--resource-arn` | The two options can't be combined | Pass `--resource-arn` only and pick the `serverless-compute` row, as step 2 does |
| The second `create-usage-limit` in step 1 fails with `Only one DISABLE usage limit allowed per feature` | The workgroup already has a `serverless-compute` usage limit with the breach action `deactivate`, for any period. A workgroup can have only one | Keep one `deactivate` limit: change the amount of the existing one with `aws redshift-serverless update-usage-limit`, or delete it before you run the line |
| The alarm fires but nobody gets a message | The topic's access policy doesn't let `cloudwatch.amazonaws.com` publish, or the subscription isn't confirmed | Fix the topic policy and confirm the subscription, then repeat Verify |

### Clean up

Delete the alarm with the `delete-alarms` line of `usage-limit-alarm.sh`, quoted as written:

```bash
cd cost-envelope
aws cloudwatch delete-alarms --alarm-names <agent-workgroup>-rpu-hours-limit --region <region>
```

List the usage limits:

```bash
cd cost-envelope
aws redshift-serverless list-usage-limits --resource-arn <workgroup-arn> \
  --query "usageLimits[].[usageLimitId,period,amount,breachAction]" --output table
```

Delete the `daily` rows with amount 150 (`emit-metric`) and amount 200 (`deactivate`); those are the two limits `serverless-ceilings.sh` created. Keep any other rows, which are your own limits. Run this once for each of those two IDs, then restore the max capacity you recorded in step 0:

```bash
cd cost-envelope
aws redshift-serverless delete-usage-limit --usage-limit-id <usage-limit-id>
aws redshift-serverless update-workgroup --workgroup-name agents-wg --max-capacity <previous-value>
```

If step 0 returned no value, the workgroup had no max capacity before setup; set `--max-capacity` to the highest RPU value your workload may use.

### Used by

All five access paths. Each path's agent workgroup is the one these limits apply to.

## Per-user limits and the model tool identity

### When to use it

On every agent's database user: a statement timeout stops one runaway query, and a connection limit with a session timeout stops an agent from holding many idle connections. When an agent's SQL can call a model through Redshift ML, give the model call its own identity, so only that tool can call the model and its input, rows and output are bounded. It addresses unbounded consumption.

### Who runs it

A database administrator.

### Prerequisites

- The agent's database user. `model-spend-summarizer.sql` names `IAMR:agent-support`, the [AgentCore custom agent](../access-layer/agentcore-custom-agent/README.md#3-create-the-database-user) path's user; each access path README sets the same limits on its own user in its step 6.
- The summarizer's database user `IAMR:agent-support-summarizer`: an IAM role `agent-support-summarizer` that has signed in once, or, as a database administrator, `CREATE USER "IAMR:agent-support-summarizer" PASSWORD DISABLE;`.
- The external model `ticket_summary` ([Redshift ML precompute](#redshift-ml-precompute) part 1, run between lines 5 and 6 of `model-spend-summarizer.sql` as Set up shows, or your own `CREATE EXTERNAL MODEL`), and the table `support.tickets`.
- If `REVOKE ASSUMEROLE ... FOR ALL` ran ([data-layer Exports and copies](../data-layer/README.md#exports-and-copies)), the model's IAM role ARN for the grant-back line.

Placeholders: `<redshift-ml-role-arn>` (the IAM role in `CREATE EXTERNAL MODEL`). Example names: `support_summary_tool`, `ticket_summary`, `agent-support-summarizer`.

### How it works

This group is the "Per user" and "Per statement" bands and the "Bounded call" box of the second diagram above. The agent's ad hoc SQL path can't call the model: only `support_summary_tool`, held by the summarizer identity, has `EXECUTE` on it. The tool's query bounds the input with `LEFT`, the rows sent to the model with an inner `LIMIT`, and the output with `maxTokens`. Superusers ignore connection limits.

### Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`model-spend-summarizer.sql`](model-spend-summarizer.sql) | Creates `support_summary_tool` with column grants on `support.tickets` and `EXECUTE` on the model, grants the model's IAM role back `FOR EXTERNAL FUNCTION`, sets `statement_timeout`, `CONNECTION LIMIT` and `SESSION TIMEOUT`, and shows the bounded model call | Set up | run as a database administrator; the last query runs as `IAMR:agent-support-summarizer` |

### Set up

As a database administrator, run lines 1 to 5 of [`model-spend-summarizer.sql`](model-spend-summarizer.sql), then part 1 of [`precompute-prompts.sql`](precompute-prompts.sql) ([Redshift ML precompute](#redshift-ml-precompute)), then lines 6 to 14 of `model-spend-summarizer.sql` (the order under [Groups](#groups)). Line 6 and the `SELECT` at the end of the file name the model without its schema, and precompute part 1 creates it in schema `support`. If `support` isn't on your `search_path`, line 6 fails with `Model "ticket_summary" does not exists` and the `SELECT` with `function ticket_summary(text, super) does not exist`, so write `support.ticket_summary` in both when you run them. Then run the `SELECT` at the end of the file as the summarizer identity. Each access path README has the same per-user lines with its own user name; for the AgentCore path's user they are:

```sql
ALTER USER "IAMR:agent-support" SET statement_timeout TO 120000;
ALTER USER "IAMR:agent-support" CONNECTION LIMIT 10 SESSION TIMEOUT 300;
```

What this does:
- Stops any statement of the agent's user after 120 seconds, allows it at most 10 connections, and ends its sessions after 300 seconds idle.
- Gives the model to one tool identity only, with `maxTokens` 200, input cut to 4,000 characters and at most 100 rows per call. `maxTokens` is case-sensitive: a lowercase `maxtokens` is ignored and the model's maximum applies.

### Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| `SELECT usename, useconnlimit FROM pg_user_info WHERE usename = 'IAMR:agent-support';` | database administrator | `useconnlimit` is `10` |
| `SHOW statement_timeout;` | the agent, in its own session | `120000`: the timeout in milliseconds |
| `SELECT support.ticket_summary(...)` | the agent | `permission denied for schema support`: the agent's role has no `USAGE` on `support` and no `EXECUTE` on the model; only the tool identity's role has both |
| The `SELECT` at the end of the file | `IAMR:agent-support-summarizer` | one summary per ticket from the last day, at most 100 rows |

### Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `does not have ASSUMEROLE permission ... for EXTERNAL FUNCTION` | `REVOKE ASSUMEROLE ON ALL FROM PUBLIC FOR ALL` ran and the model's IAM role wasn't granted back | Run the file's `GRANT ASSUMEROLE ON '<redshift-ml-role-arn>' TO ROLE support_summary_tool FOR EXTERNAL FUNCTION;` |
| Summaries are longer than expected | `maxTokens` was written in lowercase, which is ignored | Write `object('maxTokens', 200)` |
| A superuser opens more connections than the limit | Superusers ignore connection limits | Don't give agents superuser |

### Clean up

Run this after the Redshift ML precompute cleanup, which drops the objects the role has grants on. As a database administrator:

```sql
ALTER USER "IAMR:agent-support" RESET statement_timeout;
ALTER USER "IAMR:agent-support" CONNECTION LIMIT UNLIMITED;
ALTER USER "IAMR:agent-support" RESET SESSION TIMEOUT;
ALTER USER "IAMR:agent-support-summarizer" RESET statement_timeout;
REVOKE ROLE support_summary_tool FROM "IAMR:agent-support-summarizer";
DROP ROLE support_summary_tool FORCE;
DROP USER "IAMR:agent-support-summarizer";
```

Each access path README resets its own user's limits by dropping the user. If you created the IAM role `agent-support-summarizer` for this sample, delete it. `delete-role` fails with `DeleteConflict` while the role has any policy, so list and delete its inline policies first:

```bash
cd cost-envelope
aws iam list-role-policies --role-name agent-support-summarizer
aws iam delete-role-policy --role-name agent-support-summarizer --policy-name <name>
aws iam list-attached-role-policies --role-name agent-support-summarizer
aws iam delete-role --role-name agent-support-summarizer
```

Run `delete-role-policy` once for each name that `list-role-policies` returns. `list-attached-role-policies` is expected to return an empty list.

### Used by

All five access paths set the same per-user limits on their own users. The [AgentCore custom agent](../access-layer/agentcore-custom-agent/) path is the one whose agent uses the model tool identity in the post's example.

## Redshift ML precompute

### When to use it

When an agent or a scheduled job runs Redshift ML inference over rows that don't change. Redshift ML calls the model for every row the query processes, so store each result once and call the model only for rows without a stored result. It addresses unbounded consumption.

### Who runs it

- Part 1: an administrator (a superuser, or the owner of `support.tickets` with `CREATE MODEL`).
- Part 2: the materialized view's owner runs the `REFRESH`; the summarizer identity runs the `INSERT`.

### Prerequisites

- `support.tickets (ticket_id, ticket_text, created_at)`.
- `support_summary_tool`, from lines 1 to 5 of `model-spend-summarizer.sql`, before part 1; and, before part 2, the summarizer identity holding that role, from lines 6 to 14 ([Per-user limits and the model tool identity](#per-user-limits-and-the-model-tool-identity); the order under [Groups](#groups)).
- A Redshift ML IAM role associated with the namespace that may invoke the model. For a cross-Region inference profile, it needs the profile and each Region's foundation model. See [Machine learning](https://docs.aws.amazon.com/redshift/latest/dg/machine_learning.html) in the Amazon Redshift Database Developer Guide.

Placeholders: `<redshift-ml-role-arn>`, `<model-id>` (for example `us.amazon.nova-micro-v1:0`), and the values in the file's header: the prompt, 1000 (prompt length), 100 (rows per batch), 100 (`maxTokens`).

### How it works

This group is the "Infer once per row" box of the second diagram above. A materialized view holds compact prompts, a table holds one result per ticket, and each batch anti-joins the two so that the model function runs only on rows without a result. An outer `LIMIT` doesn't do this: the filter must remove rows before the function runs.

### Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`precompute-prompts.sql`](precompute-prompts.sql) | Part 1 creates the external model, the prompts materialized view, the results table and the tool's grants; part 2 is one batch: refresh the view, then infer only rows without a result | Set up | part 1 run as a database administrator; part 2 as the view owner and `IAMR:agent-support-summarizer` |

### Set up

1. Run part 1 of [`precompute-prompts.sql`](precompute-prompts.sql) once, as an administrator, after lines 1 to 5 of `model-spend-summarizer.sql` and before its lines 6 to 14 (the order under [Groups](#groups)).
2. Run part 2 for each batch: the `REFRESH` as the view owner, then the `INSERT` as the summarizer identity. Schedule it, for example with a query editor v2 scheduled query.

### Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| Part 2 twice, with no new tickets in between | view owner, then the summarizer identity | the second `INSERT` adds 0 rows and makes no model calls (the Amazon Bedrock `Invocations` metric doesn't change) |
| Part 2 after new tickets arrive | the same | one model call per new ticket |

### Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `does not have ASSUMEROLE permission ... for EXTERNAL FUNCTION` | `REVOKE ASSUMEROLE ... FOR ALL` ran and the model's IAM role wasn't granted back | Run the `GRANT ASSUMEROLE ... FOR EXTERNAL FUNCTION` line in part 1 |
| Every batch calls the model for all rows | The batch filters with an outer `LIMIT` instead of the anti-join | Keep the `LEFT JOIN ... WHERE s.ticket_id IS NULL` inside the subquery, as the file does |

### Clean up

As a database administrator:

```sql
DROP TABLE support.ticket_summaries; DROP MATERIALIZED VIEW support.mv_ticket_prompts; DROP MODEL support.ticket_summary;
```

### Used by

The [AgentCore custom agent](../access-layer/agentcore-custom-agent/) path, whose support agent reads the stored summaries in the post's example, and any path whose agent reads model output from Redshift.

## Storage compression

### When to use it

When agents create or read large tables: compressed columns and files cost less to store and scan. zstd is the default codec for Iceberg tables Redshift writes; setting it explicitly makes the choice visible. `ANALYZE COMPRESSION` estimates savings per column on managed storage. It addresses unbounded consumption.

### Who runs it

A database administrator, or the owner of each table.

### Prerequisites

- For the first statement: an Iceberg table in an S3 Tables catalog database (example name `agent-lake@s3tablescatalog`).
- For the second statement: `sales.orders` in Redshift managed storage.

Placeholders: example name `agent-lake@s3tablescatalog`; use your own.

### How it works

The diagrams above cover compute and model calls; this group covers the third cost in the envelope, data at rest. See [ANALYZE COMPRESSION](https://docs.aws.amazon.com/redshift/latest/dg/r_ANALYZE_COMPRESSION.html) in the Amazon Redshift Database Developer Guide.

### Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`storage-compression.sql`](storage-compression.sql) | Sets `compression_type` to `zstd` on an Iceberg table, and runs `ANALYZE COMPRESSION` on `sales.orders` | Set up | run as a database administrator |

### Set up

Run [`storage-compression.sql`](storage-compression.sql). Use `'snappy'` instead of `'zstd'` if you prefer speed over size.

### Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| The `ALTER TABLE` statement | database administrator | succeeds |
| `ANALYZE COMPRESSION sales.orders;` | database administrator | one row per column with the suggested encoding and the estimated reduction |

### Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| The `ALTER TABLE` statement can't find the table | The catalog database name differs from `agent-lake@s3tablescatalog` | Use your S3 Tables catalog database and namespace |

### Clean up

Nothing to undo: the first statement sets the table's default codec explicitly, and `ANALYZE COMPRESSION` only reports an estimate.

### Used by

All five access paths.

## Configured outside this repository
<!-- documented-only -->

### When to use it

For account-wide spend signals and workgroup query limits that sit around the limits above. Budgets and anomaly detection act on billing data, a few times a day; query limits and queues act on each query in real time. They address unbounded consumption.

### Who runs it

A FinOps administrator for budgets and anomaly detection; a Redshift administrator for query limits and workload management (WLM).

### Where to set it

| Control | Service | Console or API | Documentation |
| --- | --- | --- | --- |
| Per-account budgets with alerts | AWS Budgets | Billing and Cost Management console, or `aws budgets create-budget` | [Managing your costs with AWS Budgets](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html) |
| Alerts on unusual spend | AWS Cost Anomaly Detection | Billing and Cost Management console, or `aws ce create-anomaly-monitor` | [Detecting unusual spend with AWS Cost Anomaly Detection](https://docs.aws.amazon.com/cost-management/latest/userguide/manage-ad.html) |
| Query limits on a Serverless workgroup, such as maximum query execution time | Amazon Redshift Serverless | Workgroup Limits tab, or `aws redshift-serverless update-workgroup --config-parameters` | [Setting query limits](https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-workgroup-query-limits.html) |
| Query queues with their own monitoring rules on a Serverless workgroup, assigned to user roles and query groups | Amazon Redshift Serverless | Workgroup console, or `wlm_json_configuration` in `--config-parameters` | [Setting query queues](https://docs.aws.amazon.com/redshift/latest/mgmt/serverless-workgroup-query-queues.html) |
| Query monitoring rules on a provisioned cluster | Amazon Redshift | Workload management in the parameter group | [WLM query monitoring rules](https://docs.aws.amazon.com/redshift/latest/dg/cm-c-wlm-query-monitoring-rules.html) |
| WLM queues by user role on a provisioned cluster | Amazon Redshift | Workload management in the parameter group | [Implementing manual WLM](https://docs.aws.amazon.com/redshift/latest/dg/cm-c-defining-query-queues.html) |

### Used by

All five access paths.
