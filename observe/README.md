# Observe and prove

The other folders set guardrails; this one shows whether they hold. Its queries and settings answer which client and tool ran each query, which agents have no identity of their own, what each agent cost, what left Redshift, and whether the workgroup is healthy, so you can tighten grants, limits and budgets based on your own system views and logs.
In the accompanying blog post: sections "Observe and prove", "Attribute compute and inference costs", the export audit in "What the agent keeps: database-side exports and copies", and the audit queries in "Data layer: decide what the agent can reach".

## When to use it

After agents go live, on a schedule. It covers both risks: excessive agency (what an agent did, and agents that run without their own identity) and unbounded consumption (what each agent cost, and runaway loops). It's normally run by the platform or security team that owns the agent workgroups.

## Who runs it

- A monitoring role whose database user holds `sys:monitor`, for the system-view queries and the scheduled review (see Prerequisites).
- Amazon Athena users, for the CloudTrail and CUR 2.0 queries.
- A CloudTrail and Amazon EventBridge administrator, for the trail and the rule.
- A CloudWatch Logs administrator, for the data protection policy on the Bedrock invocation logs.

## How it works

![A closed loop of five numbered steps. 1, Attribute: agent-* names for agent identities plus listed exceptions, self-reported application names for tracking only, and an estimated cost on a shared workgroup. 2, Audit: SYS_QUERY_HISTORY for what ran, CloudTrail for who and when, and AgentCore and Bedrock logs joined on role and time. 3, Retain: system tables kept in S3 Tables past 7 days, to profile agents across model changes. 4, Review: run as a monitoring identity with sys:monitor, audit IGNORE RLS and tag-granted roles, and alarm on shadow agents and loops. 5, Tighten: give a shadow agent its own identity or block it, stop loops with step and retry limits, and narrow grants and ceilings.](../images/fig7-observe-loop.png)

The loop above is the concept. The diagram below shows which group reads which source.

![The observe workflow. Redshift system views, CloudTrail, EventBridge, the CUR 2.0 export in Athena and CloudWatch Logs feed five groups of checks: attribution, detection, cost ledger, export audit, and health checks and retention. Their findings feed back into tighter grants, limits and budgets. The checks run as a monitoring role with the sys:monitor role, and Athena queries CloudTrail and CUR data.](../images/observe-workflow.png)

1. Sources: Redshift system views, CloudTrail, EventBridge, the CUR 2.0 export in Athena, and CloudWatch Logs.
2. Groups: attribution, detection, cost ledger, export audit, and health checks and retention, each in its own subfolder.
3. Identity: the checks run as a monitoring role with `sys:monitor`, and Athena queries the CloudTrail and CUR data.
4. Result: findings that tighten grants, limits and budgets in the other folders.

## Groups

| Group | Question it answers | Runs as | Runs where |
| --- | --- | --- | --- |
| [attribution/](attribution/README.md) | Which client, tool and label ran each query, and which statements finished | Monitoring role with `sys:monitor`; EventBridge administrator | Query editor v2 or the Data API; EventBridge |
| [detection/](detection/README.md) | Which agents have no identity of their own, which loop, which hold idle sessions, and what each agent user can reach | Monitoring role with `sys:monitor`; a superuser for `agent-table-privileges.sql` | Query editor v2; a scheduler for runaway loops |
| [cost-ledger/](cost-ledger/README.md) | What compute and which model tokens each agent used | Monitoring role with `sys:monitor`; an Athena user with access to the CUR 2.0 table | Query editor v2; Athena |
| [export-audit/](export-audit/README.md) | What agents exported, and which objects were written to the export bucket | Monitoring role with `sys:monitor`; CloudTrail administrator; Athena user | Query editor v2; CloudTrail; Athena |
| [health-checks-and-retention/](health-checks-and-retention/README.md) | Whether the workgroup passes the scheduled health check, and whether invocation logs mask sensitive values | Monitoring role; CloudWatch Logs administrator | A scheduler host; CloudWatch Logs |

[`remaining-configuration.md`](remaining-configuration.md) lists every item the blog post mentions under "Observe and prove", with where and how to set it, and links into these subfolders.

## Prerequisites

Common to all groups:

- A monitoring role. Create it like the [Redshift MCP Server path](../access-layer/redshift-mcp-server/README.md) steps 1 and 2 (trust policy and policy), with a name outside the `agent-` prefix, for example `redshift-monitoring`, and [`../access-layer/shared/agent-data-plane-policy.json`](../access-layer/shared/agent-data-plane-policy.json) attached as the inline policy `agent-data-plane`. Its three statements are what `scheduled_review_cluster.py` needs (Discover, RunSqlOnOneWorkgroup, ReadOwnStatements). Don't give it an `agent-` name: `shadow-agents.sql` and the ledger queries would count it as an agent. Give it its own profile: add this block to `~/.aws/config`, with your account ID and your own profile in `source_profile`, instead of the `redshift-agent` append in that path's step 3:

  ```ini
  [profile redshift-monitoring]
  role_arn = arn:aws:iam::111122223333:role/redshift-monitoring
  source_profile = developer
  duration_seconds = 3600
  ```

  Then sign in once with the three `redshift-data` commands of that step 3, with `--profile redshift-monitoring`, which creates the database user `IAMR:redshift-monitoring`.
- System views show other users' rows only to a superuser or a user with `sys:monitor`; a regular user sees only its own rows. As a database administrator, in database `dev`, grant the role to the monitoring user:

  ```sql
  GRANT ROLE sys:monitor TO "IAMR:redshift-monitoring";
  ```

  See [Amazon Redshift system-defined roles](https://docs.aws.amazon.com/redshift/latest/dg/r_roles-default.html) in the Amazon Redshift Database Developer Guide.
- Run the Redshift SQL files of these groups as the monitoring role: in query editor v2 signed in as that role, or through the Data API with its profile. A superuser also sees every row. The exception is [`detection/agent-table-privileges.sql`](detection/agent-table-privileges.sql), which needs a superuser. The Athena files, [`cost-ledger/bedrock-tokens-cur2.sql`](cost-ledger/bedrock-tokens-cur2.sql) and [`export-audit/cloudtrail-s3-writes.sql`](export-audit/cloudtrail-s3-writes.sql), run in Athena instead. With the Data API, pass the file's text to `batch-execute-statement`, run `describe-statement` until it shows `FINISHED`, then read the result of the first statement (`<id>:1`). This is the form for [`detection/shadow-agents.sql`](detection/shadow-agents.sql); change the file name for the other Redshift SQL files:

  ```bash
  cd observe
  aws redshift-data batch-execute-statement --workgroup-name <agent-workgroup> --database dev \
    --sqls "$(cat detection/shadow-agents.sql)" --profile redshift-monitoring --region <region>
  aws redshift-data describe-statement --id <id> --profile redshift-monitoring --region <region> \
    --query "[Status,SubStatements[].[Id,Status,Error]]"
  aws redshift-data get-statement-result --id <id>:1 --profile redshift-monitoring --region <region>
  ```

  Each `--sqls` argument returns one result: when one argument holds two queries, both run, but only the first query's result comes back. [`export-audit/export-audit.sql`](export-audit/export-audit.sql) has two queries, so pass each one as its own argument (lines 8 to 16, and 18 to 27), then read `<id>:1` and `<id>:2`:

  ```bash
  cd observe
  aws redshift-data batch-execute-statement --workgroup-name <agent-workgroup> --database dev \
    --sqls "$(sed -n '8,16p' export-audit/export-audit.sql)" "$(sed -n '18,27p' export-audit/export-audit.sql)" \
    --profile redshift-monitoring --region <region>
  ```
- The queries find agent users with the pattern `'IAMR:agent-%'`, the naming convention of the access paths. Change the pattern if your agents are named differently.
- For the Athena files: an Athena database and a query result location.

Placeholders:
- `<monitoring-role>`: the monitoring IAM role, for example `redshift-monitoring`. Its database user is `IAMR:<monitoring-role>`.
- `<monitoring-profile>`: its AWS CLI profile, for example `redshift-monitoring`.
- `<agent-workgroup>` and `<region>`: the agent workgroup's name and Region, in the Data API commands above; `<id>`: the statement ID that `batch-execute-statement` returns.

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`remaining-configuration.md`](remaining-configuration.md) | The agent-side and scheduled configuration the blog post mentions, with where and how to set each item: scheduled health checks, runaway-loop and idle-session checks, statement events, export audit, Bedrock model invocation logging, log data protection, AgentCore Observability traces, and long-term system view retention | A checklist across the five groups | none (documentation) |

## Clean up

1. Run each group's Clean up: [attribution](attribution/README.md#clean-up), [detection](detection/README.md#clean-up), [cost-ledger](cost-ledger/README.md#clean-up), [export-audit](export-audit/README.md#clean-up), [health-checks-and-retention](health-checks-and-retention/README.md#clean-up).
2. As a database administrator in `dev`, remove the monitoring user:

   ```sql
   REVOKE ROLE sys:monitor FROM "IAMR:redshift-monitoring";
   DROP USER "IAMR:redshift-monitoring";
   ```

3. Delete the monitoring IAM role. `delete-role` fails with `DeleteConflict` while the role has any policy, so list and delete its inline policies first (`agent-data-plane`):

   ```bash
   aws iam list-role-policies --role-name redshift-monitoring
   aws iam delete-role-policy --role-name redshift-monitoring --policy-name agent-data-plane
   aws iam list-attached-role-policies --role-name redshift-monitoring
   aws iam delete-role --role-name redshift-monitoring
   ```

   Run `delete-role-policy` once for each name that `list-role-policies` returns. `list-attached-role-policies` is expected to return an empty list.
4. Remove the `[profile redshift-monitoring]` block from `~/.aws/config`.

## Used by

All five access paths: [Redshift MCP Server](../access-layer/redshift-mcp-server/), [AWS MCP Server](../access-layer/aws-mcp-server/), [custom MCP server](../access-layer/custom-mcp-server/), [AgentCore custom agent](../access-layer/agentcore-custom-agent/) and [Bedrock Knowledge Bases](../access-layer/bedrock-knowledge-base/). Their optional Verify rows use the detection and attribution queries.
