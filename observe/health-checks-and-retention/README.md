# Health checks and retention: scheduled review and protected logs

A scheduled health check of the agent workgroup with the Amazon Redshift MCP Server's `review_cluster` tool, run without an AI assistant, and a CloudWatch Logs data protection policy that masks email addresses and card numbers in Amazon Bedrock model invocation logs. This README also points to where to keep system view history and model invocation logs for longer than the views hold them.
In the accompanying blog post: section "Observe and prove".

## When to use it

After agents go live. The scheduled review runs the workgroup health checks of `review_cluster` every day, without anyone opening an AI assistant, so problems show up as findings before agents make them worse; it addresses unbounded consumption. Invocation logs record the prompts and answers of every model call, so mask the sensitive values in them before people read them. Long-term retention lets you profile agents across model and prompt changes.

## Who runs it

- The monitoring role (for example `redshift-monitoring`), on a scheduler host, for `scheduled_review_cluster.py`.
- A CloudWatch Logs administrator, for the data protection policy.
- An Amazon Bedrock administrator, for model invocation logging; a Redshift administrator, for system table retention.

## Prerequisites

- The monitoring role and its profile, created as in the [observe Prerequisites](../README.md#prerequisites), with `agent-data-plane-policy.json` attached and `sys:monitor` granted to its database user. These permissions and `sys:monitor` are enough for `review_cluster` with `awslabs.redshift-mcp-server` 0.1.2 on Redshift Serverless.
- On the scheduler host: Python 3.10 or later, [uv](https://docs.astral.sh/uv/) (for `uvx`), and the MCP Python SDK 1.x.
- Bedrock model invocation logging turned on to a CloudWatch Logs group, for the data protection policy. See [Monitor model invocation using CloudWatch Logs and Amazon S3](https://docs.aws.amazon.com/bedrock/latest/userguide/model-invocation-logging.html) in the Amazon Bedrock User Guide.

Placeholders:
- In `scheduled_review_cluster.py`: `<agent-workgroup>`, `<monitoring-profile>`, `<region>`, `dev` (the database), and the output folder (the file's own folder by default).
- `<log-group-name>`: the Bedrock model invocation log group.

## How it works

This group is the HEALTH CHECKS AND RETENTION box of the [observe workflow](../../images/observe-workflow.png); it reads system views through `review_cluster`, and CloudWatch Logs.

- `scheduled_review_cluster.py` starts the Redshift MCP Server (pinned to version 0.1.2) over stdio with the monitoring profile, calls `review_cluster` once for the workgroup, writes the result to `review-<UTC>.json`, prints a summary, and exits 1 when there are findings, so the scheduler or a wrapper can alert.
- `invocation-logs-data-protection.json` audits and masks the managed data identifiers `EmailAddress` and `CreditCardNumber` in the log group. See [Help protect sensitive log data with masking](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/mask-sensitive-log-data.html) in the Amazon CloudWatch Logs User Guide.
- Retention: Redshift system views keep a short history. To keep SYS_QUERY_HISTORY, SYS_CONNECTION_LOG and SYS_USERLOG for longer, deliver them to Apache Iceberg tables in Amazon S3 Tables and query them from Redshift or Athena; see [System table integration with S3 Tables](https://docs.aws.amazon.com/redshift/latest/mgmt/system-table-s3-tables.html) in the Amazon Redshift Management Guide. Model invocation logging can also deliver to Amazon S3 for long-term storage (see the Bedrock link in Prerequisites).

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`scheduled_review_cluster.py`](scheduled_review_cluster.py) | Python script that runs `review_cluster` once through the Redshift MCP Server, saves the result as JSON, and exits 1 on findings | Set up step 1, on a schedule | runs as the monitoring role, through `<monitoring-profile>` |
| [`invocation-logs-data-protection.json`](invocation-logs-data-protection.json) | CloudWatch Logs data protection policy that audits and masks email addresses and card numbers. Add the data identifiers your data needs | Set up step 2, `put-data-protection-policy` | none (log group policy) |

## Set up

Run each block from the repository root; each one starts with the `cd` it needs.

### 1. Run the review on a schedule

Replace `<agent-workgroup>`, `<monitoring-profile>` and `<region>` at the top of [`scheduled_review_cluster.py`](scheduled_review_cluster.py). Install the MCP Python SDK and run the review once:

```bash
cd observe/health-checks-and-retention
pip install "mcp>=1,<2"
python3 scheduled_review_cluster.py
```

Then schedule it, for example daily at 06:00, with the lines in the file's header. Copy the file to the folder the line names first:

```text
cron (Linux, macOS):  0 6 * * * cd /opt/redshift-review && python3 scheduled_review_cluster.py >> review.log 2>&1
Windows Task Scheduler:
  schtasks /Create /SC DAILY /ST 06:00 /TN redshift-review-cluster /TR "python C:\redshift-review\scheduled_review_cluster.py"
```

Alert on a non-zero exit code.

What this does:
- Each run writes `review-<UTC>.json` next to the script and prints one summary line, plus one line per finding.

### 2. Mask sensitive values in invocation logs

As a CloudWatch Logs administrator:

```bash
cd observe/health-checks-and-retention
aws logs put-data-protection-policy --log-group-identifier <log-group-name> \
  --policy-document file://invocation-logs-data-protection.json
```

What this does:
- Masks email addresses and card numbers in new log events of the group, and audits each match.

### 3. Keep history for longer

Turn on the system table integration with Amazon S3 Tables for the agent workgroup, as the Retention bullet under How it works describes. No file in this repository sets it.

## Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| `python3 scheduled_review_cluster.py` | monitoring role, through `<monitoring-profile>` | `signals_evaluated=<n> findings=<n> file=<path>/review-<UTC>.json`, one line per finding, and exit code 1 when there are findings (0 otherwise) |
| A Bedrock model call whose prompt contains a sample email address, then the log event in CloudWatch Logs | Bedrock caller; CloudWatch Logs reader | the email address appears masked in the log event |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `RuntimeError` with the tool's error text | `review_cluster` returned an error, for example because the monitoring role can't sign in to the workgroup or its database user lacks `sys:monitor` | Check the profile, the `agent-data-plane` policy and the `sys:monitor` grant ([observe Prerequisites](../README.md#prerequisites)) |
| `uvx` isn't found | uv isn't installed on the scheduler host, or isn't on the scheduler's `PATH` | Install uv, and use its full path in the schedule if needed |
| A sensitive value isn't masked | A managed data identifier doesn't match every format of a value. For example, `CreditCardNumber` masks other card numbers but not the common test number `4111111111111111` | Check the masked log events against samples of your own data, and add identifiers your data needs |

## Clean up

- Delete the scheduled task: the cron line, or the Task Scheduler task `redshift-review-cluster`. Delete the `review-*.json` files if you don't need them.
- Remove the data protection policy:

  ```bash
  cd observe/health-checks-and-retention
  aws logs delete-data-protection-policy --log-group-identifier <log-group-name>
  ```

- The monitoring role and its profile are removed by the [observe Clean up](../README.md#clean-up).

## Used by

All five access paths: the review covers the workgroup their agents use. The [Redshift MCP Server](../../access-layer/redshift-mcp-server/) path uses the same server version.
