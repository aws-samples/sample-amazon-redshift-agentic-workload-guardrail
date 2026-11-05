# Cost ledger: compute and model tokens per agent

Two queries that put a cost on each agent: Redshift compute per agent database user and query label, from system views, and Amazon Bedrock tokens and cost per calling IAM role and agent tag, from a CUR 2.0 export in Amazon Athena.
In the accompanying blog post: section "Attribute compute and inference costs".

## When to use it

Daily or weekly after agents go live, for chargeback and to see which agent drives spend before a limit or budget stops it. It addresses unbounded consumption. With one database user and one IAM role per agent, SYS_QUERY_HISTORY and CUR 2.0 become a ledger per agent.

## Who runs it

- The monitoring role with `sys:monitor`, for `compute-ledger.sql`.
- An Athena user with read access to the CUR 2.0 table, for `bedrock-tokens-cur2.sql`.

## Prerequisites

- `sys:monitor` for the monitoring user ([observe Prerequisites](../README.md#prerequisites)).
- For `bedrock-tokens-cur2.sql`: a CUR 2.0 data export created with "Include caller identity (IAM principal) allocation data", and an Athena table over it. See [What is AWS Data Exports?](https://docs.aws.amazon.com/cur/latest/userguide/what-is-data-exports.html) and [Using IAM principal for cost allocation](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/iam-principal-cost-allocation.html).
- For its `agent_id` column: the `agent-id` tag on each IAM role that calls Bedrock (for Redshift ML, the `IAM_ROLE` in `CREATE EXTERNAL MODEL`), activated as the cost allocation tag `iamPrincipal/agent-id`. The [attribution-to-budget-action checklist](../../checklist/attribution-to-budget-action.md) walks through it.

Placeholders:
- `<cur_database>.<cur_table>`: the Athena database and table over the CUR 2.0 export.
- `<start-date>` and `<end-date>`: the date range, as `YYYY-MM-DD`.
- `agent-id`: the tag key.
- `'IAMR:agent-%'` and the 7-day window in `compute-ledger.sql`.

## How it works

This group is the COST LEDGER box of the [observe workflow](../../images/observe-workflow.png); it reads system views and the CUR 2.0 export.

- `compute-ledger.sql` sums execution time per day, agent user and query label from SYS_QUERY_HISTORY, takes each one's share of the workgroup's execution time, and applies that share to the RPU-hours SYS_SERVERLESS_USAGE charged for the day. Redshift Serverless charges the workgroup, not single queries, so `est_rpu_hours` is an estimate; on a dedicated agent workgroup, use the workgroup's total instead.
- `bedrock-tokens-cur2.sql` sums Bedrock input and output token usage and unblended cost per day, IAM principal and `iamPrincipal/agent-id` tag. It folds role session ARNs into the role ARN.

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`compute-ledger.sql`](compute-ledger.sql) | Queries, execution seconds, share of the workgroup's execution time and estimated RPU-hours per day, agent user and query label, for the last 7 days | Set up step 1 | runs as the monitoring role with `sys:monitor` |
| [`bedrock-tokens-cur2.sql`](bedrock-tokens-cur2.sql) | Bedrock token usage and cost per day, IAM role and agent tag, from CUR 2.0 (Athena) | Set up step 2 | runs as an Athena user with access to the CUR 2.0 table |

## Set up

### 1. Compute per agent

Run [`compute-ledger.sql`](compute-ledger.sql) as the [monitoring role](../README.md#prerequisites), in database `dev`. Sample output (illustrative values):

```text
day          | agent_user         | query_label | queries | exec_seconds | pct_of_workgroup | est_rpu_hours
<yyyy-mm-dd> | IAMR:agent-support | default     | <n>     | <seconds>    | <percent>        | <rpu-hours>
```

### 2. Model tokens per agent

Replace `<cur_database>.<cur_table>`, `<start-date>` and `<end-date>` in [`bedrock-tokens-cur2.sql`](bedrock-tokens-cur2.sql) and run it in Athena. Sample output (illustrative values):

```text
usage_day    | principal                                       | agent_id   | line_item_usage_type | pricing_unit | usage_amount | unblended_cost
<yyyy-mm-dd> | arn:aws:iam::111122223333:role/<model-role-name> | <agent-id> | <usage-type>         | <unit>       | <n>          | <usd>
```

## Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| `compute-ledger.sql` | monitoring role | one row per day, agent user and query label, with queries, seconds, share and estimated RPU-hours |
| `bedrock-tokens-cur2.sql` | Athena user | one row per day, role, agent tag and usage type with tokens and cost; the `agent_id` column holds `<agent-id>` for tagged roles |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `compute-ledger.sql` lists only the monitoring user's own queries | The monitoring user doesn't hold `sys:monitor` | Grant it ([observe Prerequisites](../README.md#prerequisites)) |
| `agent_id` is empty | The tag isn't active as a cost allocation tag yet; tags appear for activation only after the tagged role has called Bedrock, and activation can take up to 24 hours | Activate `iamPrincipal/agent-id` in the management account and wait for the next CUR delivery |
| Athena reports a column it can't resolve | Your export's schema or activated tags differ from the column names the file uses | Check the file against your CUR 2.0 table's columns before you rely on its numbers |
| Some model spend is missing | Models sold through AWS Marketplace can bill under another product code than `AmazonBedrock` | Add that product code to the `WHERE` clause |

## Clean up

These are queries only; there's nothing to undo.

## Used by

- All five access paths: each agent's database user and IAM role are the keys of the ledger.
- [`../../cost-envelope/bedrock-budget-action/`](../../cost-envelope/bedrock-budget-action/README.md): the budget acts on the same spend per agent tag.
