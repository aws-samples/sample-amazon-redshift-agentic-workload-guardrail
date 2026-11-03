# Attribution: which client and tool ran each query

These files tie each query to the client, tool and label that ran it: a query per database user, application name and query label, and a Data API statement name with an EventBridge event when each statement finishes. With one database user per agent, they show what each agent ran without reading its SQL.
In the accompanying blog post: section "Observe and prove".

## When to use it

After agents go live, to see which client and which tool ran what, and to track agents over time. It addresses excessive agency: you can only narrow what an agent does once you can see it. Application names are self-reported by the client, so use them to track, not to control; the database user and the IAM role are what the guardrails act on.

## Who runs it

- The monitoring role with `sys:monitor`, for `queries-per-client.sql`.
- An EventBridge administrator, for the rule.
- The tool's own IAM role, which sets the statement name and `WithEvent` on its Data API calls.

## Prerequisites

- `sys:monitor` for the monitoring user ([observe Prerequisites](../README.md#prerequisites)).
- For the rule: permission for `events:PutRule` and `events:PutTargets`, and an Amazon SQS queue whose access policy lets `events.amazonaws.com` send messages, with `aws:SourceArn` set to the rule's ARN. See [Using resource-based policies for Amazon EventBridge](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-use-resource-based.html).
- A caller that sets `WithEvent=True`. The sample custom MCP server sets `StatementName` but not `WithEvent`. To test the rule, run the test command in Verify, which needs the [custom MCP server path](../../access-layer/custom-mcp-server/README.md#3-create-the-database-user)'s `sales-metrics` profile, or any agent profile. To get events from your own copy of the server, add `WithEvent=True` to its `execute_statement` call.

Placeholders:
- `<rule-name>`: the EventBridge rule's name.
- `<region>`: the Region of the agent workgroup.
- `<queue-arn>` and `<queue-url>`: the SQS queue's ARN and URL.
- `<agent-workgroup>`: the agent workgroup's name.

## How it works

This group is the ATTRIBUTION box of the [observe workflow](../../images/observe-workflow.png); it reads system views and EventBridge events.

- `queries-per-client.sql` joins SYS_CONNECTION_LOG, where each session records its `application_name`, to SYS_QUERY_HISTORY, and counts queries per database user, application name and query label over the last day.
- A tool that calls the Data API itself can set `StatementName` on each call, and `WithEvent=True` to receive a "Redshift Data Statement Status Change" event when the statement finishes. [`data-api-statement-events.md`](data-api-statement-events.md) shows where the statement name appears (ListStatements, CloudTrail, EventBridge) and where it doesn't (DescribeStatement, SYS_QUERY_HISTORY). See [Monitoring events for the Amazon Redshift Data API in Amazon EventBridge](https://docs.aws.amazon.com/redshift/latest/mgmt/data-api-monitoring-events.html).
- In CloudTrail, every Data API call shows the agent's role session in `userIdentity.arn`. To tell the people or workloads behind one role apart, require a role session name with the `sts:RoleSessionName` condition key, or a source identity with `sts:SourceIdentity`, in the role's trust policy; CloudTrail then records the value with every action of that session. See [Monitor and control actions taken with assumed roles](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_control-access_monitor.html) in the IAM User Guide.

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`queries-per-client.sql`](queries-per-client.sql) | Queries per database user, client application name and query label over the last day | Set up step 1 | runs as the monitoring role with `sys:monitor` |
| [`data-api-statement-events.md`](data-api-statement-events.md) | Where a tool's `StatementName` shows up, the `ListOwnStatements` statement, the rule commands, an example event and their cleanup | Set up step 2 | none (documentation) |
| [`data-api-statement-events-rule.json`](data-api-statement-events-rule.json) | EventBridge event pattern that matches only "Redshift Data Statement Status Change" events from `aws.redshift-data`. A pattern with the source alone also matches the CloudTrail event of every Data API call | Set up step 2, `put-rule --event-pattern` | none (event pattern) |

## Set up

Run each block from the repository root; each one starts with the `cd` it needs.

### 1. Count queries per client

Run [`queries-per-client.sql`](queries-per-client.sql) as the [monitoring role](../README.md#prerequisites), in database `dev`, in query editor v2 or through the Data API. Sample output (illustrative values):

```text
db_user                      | app                                         | label   | queries
IAMR:agent-redshift-readonly | awslabs/mcp/redshift-mcp-server/<version>   | <label> | <n>
```

`queries-per-client.sql` replaces any 36-character statement ID inside an application name with `<statement-id>`, so Data API sessions group together.

### 2. Create the rule for statement events

The commands from "The rule" in [`data-api-statement-events.md`](data-api-statement-events.md), as written there:

```bash
cd observe/attribution
aws events put-rule --name <rule-name> --event-pattern file://data-api-statement-events-rule.json --region <region>
aws events put-targets --rule <rule-name> --targets Id=queue,Arn=<queue-arn> --region <region>
```

What this does:
- Creates the rule `<rule-name>`, which matches only statement status-change events.
- Sends each matching event to the SQS queue, with the target ID `queue`.

## Verify

Test the rule with one statement that sets a statement name and `--with-event`, then read the queue:

```bash
cd observe/attribution
aws redshift-data execute-statement --workgroup-name <agent-workgroup> --database dev --sql "SELECT 1" \
  --statement-name sales-metrics:rule-test --with-event --profile sales-metrics --region <region>
aws sqs receive-message --queue-url <queue-url> --wait-time-seconds 20 --region <region>
```

| Check | Run as | Expected result |
| --- | --- | --- |
| `queries-per-client.sql` | monitoring role | one row per database user, application name and label, with a query count |
| `receive-message` after the test command | SQS queue owner | within a minute, one "Redshift Data Statement Status Change" event with `detail.statementName` `sales-metrics:rule-test` and `detail.state` `FINISHED` |
| The same test without `--with-event` | the agent profile | no event |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `queries-per-client.sql` returns only the monitoring user's own rows | The monitoring user doesn't hold `sys:monitor` | Grant it ([observe Prerequisites](../README.md#prerequisites)) |
| No event reaches the queue | The caller didn't set `WithEvent=True`, or the queue's access policy doesn't let `events.amazonaws.com` send for this rule | Set `WithEvent=True` (the test command uses `--with-event`); fix the queue policy |
| The queue receives an event for every Data API call | The rule's pattern has only `source: aws.redshift-data`, which also matches the CloudTrail events | Use `data-api-statement-events-rule.json`, which also matches the detail type |
| `list-statements --statement-name` fails with AccessDenied | `ListStatements` has no statement owner, so a statement-owner condition never matches it | Allow it in its own statement, as `data-api-statement-events.md` shows |

## Clean up

The cleanup lines of [`data-api-statement-events.md`](data-api-statement-events.md):

```bash
cd observe/attribution
aws events remove-targets --rule <rule-name> --ids queue --region <region>
aws events delete-rule --name <rule-name> --region <region>
```

Then delete the SQS queue if you created it for this. `queries-per-client.sql` only reads system views; there's nothing to undo.

## Used by

- The [custom MCP server](../../access-layer/custom-mcp-server/) path, whose tool sets `StatementName`, and any tool that calls the Data API itself.
- All five access paths, for `queries-per-client.sql`.
