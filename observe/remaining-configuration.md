# Remaining observability configuration

Purpose: the agent-side and scheduled configuration that "Observe and prove" mentions but doesn't show, with where to set it and how.
Post section: "Observe and prove" ("The sample repository lists the remaining configuration, including scheduled review_cluster health checks").
Prerequisites: administrator access to the account and Region of the agent workgroup; a monitoring IAM role whose database user holds `sys:monitor` (see [`health-checks-and-retention/scheduled_review_cluster.py`](health-checks-and-retention/scheduled_review_cluster.py)).
Placeholders: `<agent-workgroup>`, `<region>`, `<log-group-name>`, `<monitoring-profile>`.

Run the commands on this page from the `observe` folder: `cd observe`

| Item | Where | How |
| --- | --- | --- |
| Scheduled review_cluster health checks | A host or container with Python, `uv` and the monitoring profile | [`health-checks-and-retention/scheduled_review_cluster.py`](health-checks-and-retention/scheduled_review_cluster.py): starts the Redshift MCP Server (pinned version), calls `review_cluster` for the workgroup, writes `review-<UTC>.json`, exits 1 when there are findings. Schedule it with cron or Task Scheduler (lines in the file's header) and alert on a non-zero exit |
| Runaway-loop check under a monitoring identity | Same scheduler and identity | Run [`detection/runaway-loops.sql`](detection/runaway-loops.sql) every 15 minutes through the Data API as the monitoring role, and publish the row count as a custom metric with an alarm (`aws cloudwatch put-metric-data`, then `put-metric-alarm` as in [`cost-envelope/usage-limit-alarm.sh`](../cost-envelope/usage-limit-alarm.sh)) |
| Idle sessions per database user | Same scheduler and identity | [`detection/idle-sessions.sql`](detection/idle-sessions.sql) with a threshold, for sizing CONNECTION LIMIT and SESSION TIMEOUT |
| Data API statement names and events | The custom tool, plus an EventBridge rule | [`attribution/data-api-statement-events.md`](attribution/data-api-statement-events.md), [`attribution/data-api-statement-events-rule.json`](attribution/data-api-statement-events-rule.json) |
| Export audit | Same scheduler and identity; a trail for bucket writes | [`export-audit/export-audit.sql`](export-audit/export-audit.sql), [`export-audit/cloudtrail-s3-data-events.sh`](export-audit/cloudtrail-s3-data-events.sh), [`export-audit/cloudtrail-s3-writes.sql`](export-audit/cloudtrail-s3-writes.sql) |
| Bedrock model invocation logging | Amazon Bedrock settings, per account and Region | Turn on model invocation logging to a CloudWatch Logs group (and optionally S3) in the Bedrock console or with `aws bedrock put-model-invocation-logging-configuration`. It logs every model call in the account and Region, including Redshift ML calls, with the caller's role |
| CloudWatch Logs data protection on the invocation log group | CloudWatch Logs | `aws logs put-data-protection-policy --log-group-identifier <log-group-name> --policy-document file://health-checks-and-retention/invocation-logs-data-protection.json` (audits and masks email addresses and card numbers; add the identifiers your data needs; the policy file is [`health-checks-and-retention/invocation-logs-data-protection.json`](health-checks-and-retention/invocation-logs-data-protection.json)). A managed data identifier doesn't match every format of a value, so check the masked log events against samples of your own data |
| AgentCore Observability traces | Amazon Bedrock AgentCore, per agent runtime | Turn on observability for the runtime (CloudWatch Transaction Search and the agent's OpenTelemetry instrumentation), then join spans to Redshift on the IAM role and time window: SYS_QUERY_HISTORY by database user (`IAMR:<role>`) and start time, CloudTrail Data API events by role session |
| Long-term record of system views | Redshift system table integration with Amazon S3 Tables | Deliver SYS_QUERY_HISTORY, SYS_CONNECTION_LOG and SYS_USERLOG to Iceberg tables; query them from Redshift or Athena (see [System table integration with S3 Tables](https://docs.aws.amazon.com/redshift/latest/mgmt/system-table-s3-tables.html) in the Amazon Redshift Management Guide) |

Cleanup: delete the scheduled task, `aws logs delete-data-protection-policy --log-group-identifier <log-group-name>`, and the trail and rule as their files describe.
