# Data API statement names and status events

Purpose: name each tool's Data API statements and receive an event when each one finishes, so you can see which tool and which role ran what, without reading SQL.
Post section: "Observe and prove" ("Custom tools can add a query_group label, SQL comment, StatementName, or SDK application ID") and the custom MCP server in "Data plane: a narrow tool surface on every path".
Prerequisites: a tool that calls the Data API itself (a custom MCP server, Lambda function or agent tool); permission for `events:PutRule` and `events:PutTargets`, and a target such as an Amazon SQS queue whose policy lets `events.amazonaws.com` send with `aws:SourceArn` set to the rule.
Placeholders: `<rule-name>`, `<region>`, `<queue-arn>`.

## Where StatementName shows up

The tool sets `StatementName` (and, for events, `WithEvent=True`) on `ExecuteStatement` or `BatchExecuteStatement`, as `access-layer/custom-mcp-server/sales_metrics_mcp.py` does for `StatementName` (`sales-metrics:daily_revenue`). That server doesn't set `WithEvent`; add it to your tool's call to receive the events below.

| Place | StatementName | Who ran it |
| --- | --- | --- |
| `ListStatements` (filter with `--statement-name <prefix>`) | yes | scoped to the caller's role (`--role-level`), or to its session |
| CloudTrail `ExecuteStatement` event, `requestParameters.statementName` | yes | `userIdentity.arn` (role session); the SQL is shown as `***OMITTED***` |
| EventBridge "Redshift Data Statement Status Change" event (`WithEvent=True` only), `detail.statementName` | yes | `detail.principal` (role session) |
| `DescribeStatement`, SYS_QUERY_HISTORY | no | use the SQL comment for query history |

`ListStatements` has no statement owner, so a `redshift-data:statement-owner-iam-userid` condition never matches it; allow it in its own statement:

```json
{ "Sid": "ListOwnStatements", "Effect": "Allow", "Action": "redshift-data:ListStatements", "Resource": "*" }
```

`ListStatements` returns only statements run by the caller's own IAM role: by default from all of that role's sessions, and with `--no-role-level` only from the current session.

## The rule

`data-api-statement-events-rule.json` matches only the status-change events. A pattern with `source: aws.redshift-data` alone also matches the "AWS API Call via CloudTrail" event of every Data API call.

```bash
cd observe/attribution
aws events put-rule --name <rule-name> --event-pattern file://data-api-statement-events-rule.json --region <region>
aws events put-targets --rule <rule-name> --targets Id=queue,Arn=<queue-arn> --region <region>
```

Example event:

```json
{
  "detail-type": "Redshift Data Statement Status Change",
  "source": "aws.redshift-data",
  "detail": {
    "principal": "arn:aws:sts::111122223333:assumed-role/agent-sales-metrics/session-name",
    "statementName": "sales-metrics:daily_revenue",
    "statementId": "<statement-id>",
    "state": "FINISHED",
    "rows": 1.0
  }
}
```

Cleanup: `aws events remove-targets --rule <rule-name> --ids queue --region <region>` and `aws events delete-rule --name <rule-name> --region <region>`.
