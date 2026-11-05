# AgentCore custom agent: one role per agent, fixed SQL per tool

On this path a custom agent on Amazon Bedrock AgentCore calls tools that run in AgentCore Runtime or as AWS Lambda functions behind AgentCore Gateway, and each tool reaches Redshift as the agent's own IAM role. It addresses excessive agency (fixed SQL per tool, one role per agent, AgentCore Policy at the gateway, a database role with narrow grants) and unbounded consumption (step and retry limits, connection limits and session timeouts for driver connections).
In the accompanying blog post: section "Data plane: a narrow tool surface on every path".

## When to use this path

Use it for custom agents in production on Amazon Bedrock AgentCore, with tools that run in AgentCore Runtime or as Lambda functions behind AgentCore Gateway. It's normally set up by the team that builds the agent, with an IAM administrator for the execution role and a database administrator for the database role and limits. This folder covers the identity, policy, database setup and limits; it doesn't deploy an agent.

Use another path if the tools run as an MCP server next to an application (the `custom-mcp-server` path), or if end users ask questions through a managed knowledge base (the `bedrock-knowledge-base` path). See [Choose your path](../README.md#choose-your-path).

## How the agent reaches Redshift

### Runtime tool

The tool runs in the AgentCore Runtime session's microVM under the runtime execution role. It calls the Redshift Data API, or connects with a driver such as `redshift_connector` with IAM authentication. Either way, the sign-in uses `redshift-serverless:GetCredentials` as the execution role.

### Gateway tool

AgentCore Gateway invokes a Lambda function for each tool call. The function calls the Data API, or connects with a driver, under the function's execution role. When a policy engine is associated with the gateway, [Policy in Amazon Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy.html) evaluates each request against your policies before the tool runs.

## Which identity Redshift sees

Redshift sees the runtime execution role or the Lambda function role as a database user named after the role, for example `IAMR:agent-support` for the role `agent-support`. Use one role per agent, so each agent has its own database user, grants, limits and audit trail.

Least privilege needs both scopes: the IAM policy limits which workgroup and which APIs the role can call, and the database permissions of `agent_support` limit what its SQL can read.

## Workflow

![Workflow for a custom agent on Amazon Bedrock AgentCore. The agent calls a tool in AgentCore Runtime or a Lambda function behind AgentCore Gateway. The runtime execution role or the function role signs in to Redshift, which maps it to a database user such as IAMR:agent-support. Guardrails: step and retry limits in the agent framework, AgentCore Policy at the gateway, one IAM role per agent scoped to one workgroup, connection limits and session timeouts for driver connections, and database grants, row-level security and masking.](../../images/access-path-agentcore-custom-agent.png)

1. Client: the agent on AgentCore Runtime decides which tool to call, with step and retry limits in the agent framework.
2. Tool: a Runtime tool (Data API or driver), or a Lambda tool behind AgentCore Gateway, where AgentCore Policy checks each call.
3. IAM role and policy: the runtime execution role or the Lambda function role, each with `agent-data-plane-policy.json`; one role per agent, SQL on one workgroup.
4. Sign-in and database user: `IAMR:agent-support` through `GetCredentials` sign-in, with `CONNECTION LIMIT` and `SESSION TIMEOUT` for idle driver connections.
5. Database role and permissions: `agent_support`, with its grants, row-level security and masking.
6. Data: Redshift managed storage, or Apache Iceberg tables governed by Lake Formation permissions.

## Guardrails on this path

| Layer | Guardrail | Where it's set | File or setting |
| --- | --- | --- | --- |
| Agent layer | Step and retry limits, so a loop can't run unbounded | Agent framework | Your agent's configuration |
| Access layer | Per-action tools, each one fixed, parameterized statement with its own `StatementName` and SQL comment | Tool code | Step 7 |
| Access layer | AgentCore Policy evaluates each tool call at the gateway (Gateway tools only) | AgentCore Gateway | [Policy in Amazon Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy.html) |
| Access layer | One role per agent; SQL on one workgroup; results of the role's own statements only | IAM | [`agent-data-plane-policy.json`](../shared/agent-data-plane-policy.json) |
| Data layer | Grants on one database role, row-level security, column privileges, masking | Redshift | [`agent-role.sql`](../../data-layer/agent-role.sql), [`fine-grained-access.sql`](../../data-layer/fine-grained-access.sql) |
| Cost envelope | `statement_timeout`, `CONNECTION LIMIT` and `SESSION TIMEOUT` on the user, because driver connections stay open while idle | Redshift | Step 6 |
| Cost envelope | End each conversation's runtime session with `StopRuntimeSession`, so its microVM and the connections the tool opened in it don't stay open | AgentCore Runtime | [Stop a running session](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-stop-session.html) |

## Files

This folder has no files; set up uses the linked files below: [`../shared/agent-data-plane-policy.json`](../shared/agent-data-plane-policy.json), [`../../data-layer/agent-role.sql`](../../data-layer/agent-role.sql) and [`../../data-layer/fine-grained-access.sql`](../../data-layer/fine-grained-access.sql).

## Prerequisites

- An Amazon Redshift Serverless workgroup for agents, and the example schema `sales.orders`, `sales.customers` and `sales.payments` (see the root README).
- An agent on Amazon Bedrock AgentCore Runtime, and for Gateway tools an AgentCore Gateway with a Lambda target. A network path from the runtime or the function to the workgroup endpoint if the tool uses a driver; the Data API needs no network path to the workgroup.
- An IAM administrator for steps 1 and 2, and a database administrator for steps 3 to 6. The SQL on this page runs in database `dev`.

Database identity on this path:

| IAM role | Database user | Database role | Where the grants come from | Row-level security and masking |
| --- | --- | --- | --- | --- |
| `agent-support` (runtime execution role or Lambda function role) | `IAMR:agent-support` | `agent_support` | Step 4: `agent-role.sql` as is; it already names `IAMR:agent-support` | Step 5: `fine-grained-access.sql` as is; its policies attach to `agent_support` |

Placeholders in this path:
- `<agent-workgroup-id>`: the agent workgroup's ID, in `agent-data-plane-policy.json`.
- `111122223333` and `us-east-1`: the example account ID and Region, in the trust policy and the data plane policy. Replace them with yours.
- `agents-wg` and `dev` in the step 7 excerpt: your workgroup and database.
- `<policy-arn>`: the ARN of a managed policy you attached to the runtime or function role, in Clean up step 3.

## Set up

Run each block from the repository root; each one starts with the `cd` it needs.

### 1. Create the IAM role

For a Runtime tool, the execution role trusts AgentCore Runtime. This trust policy is the one in [IAM Permissions for AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-permissions.html), with the example account and Region:

```bash
cd access-layer/agentcore-custom-agent
cat > agent-support-runtime-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "AssumeRolePolicy", "Effect": "Allow",
      "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "111122223333" },
        "ArnLike": { "aws:SourceArn": "arn:aws:bedrock-agentcore:us-east-1:111122223333:*" } } }
  ]
}
EOF
aws accessanalyzer validate-policy --policy-type RESOURCE_POLICY \
  --validate-policy-resource-type AWS::IAM::AssumeRolePolicyDocument \
  --policy-document file://agent-support-runtime-trust.json --query "findings[?findingType=='ERROR']"
aws iam create-role --role-name agent-support \
  --assume-role-policy-document file://agent-support-runtime-trust.json
```

For a Gateway tool, the Lambda function's execution role trusts the Lambda service principal `lambda.amazonaws.com` instead (see [Lambda execution role](https://docs.aws.amazon.com/lambda/latest/dg/lambda-intro-execution-role.html) in the AWS Lambda Developer Guide):

```bash
cd access-layer/agentcore-custom-agent
cat > agent-support-lambda-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "lambda.amazonaws.com" }, "Action": "sts:AssumeRole" }
  ]
}
EOF
aws iam create-role --role-name agent-support \
  --assume-role-policy-document file://agent-support-lambda-trust.json
```

What this does:
- Writes a generated trust file in this folder (don't commit it) and creates the role `agent-support` for one of the two variants.
- The runtime role also needs the permissions on the AgentCore Runtime permissions page (for example to pull its image and write logs), and the Lambda role needs permission to write its logs. Add them as their own policies; this path adds only the Redshift permissions.

### 2. Attach the policy

Replace `111122223333`, `us-east-1` and `<agent-workgroup-id>` in `../shared/agent-data-plane-policy.json` first, and attach it with `file://` so the shell doesn't rewrite `${aws:userid}`.

```bash
cd access-layer/agentcore-custom-agent
aws iam put-role-policy --role-name agent-support --policy-name agent-data-plane \
  --policy-document file://../shared/agent-data-plane-policy.json
```

What this does:
- Adds the inline policy `agent-data-plane`. Data API tools use all three statements. Driver tools use only `GetCredentials` from `RunSqlOnOneWorkgroup`, and need network access from the runtime or the function to the workgroup endpoint.

### 3. Create the database user

The tool's first call creates `IAMR:agent-support` (a Data API sign-in, or a driver connection with IAM authentication). The execution role trusts only AgentCore or Lambda, so you can't sign in as it from your machine. Run steps 4 to 6 after the first call, or create the user ahead of time as a database administrator:

```sql
CREATE USER "IAMR:agent-support" PASSWORD DISABLE;
```

What this does:
- Creates the database user that the role maps to at sign-in, with no password and no privileges yet.

### 4. Grant database permissions

As a database administrator, run [`agent-role.sql`](../../data-layer/agent-role.sql) as is. It creates `agent_support` with `USAGE` on `sales` and `SELECT` on `sales.orders` and `sales.payments`, and grants it to `IAMR:agent-support`. If another path already created `agent_support`, run only its last line.

What this does:
- Privileges go to the database role `agent_support`, never to the user.

### 5. Add row-level security and masking

As a database administrator, run [`fine-grained-access.sql`](../../data-layer/fine-grained-access.sql) as is. Skip this step if you already ran the file for another path; the policies attach to `agent_support`, so every user that holds the role is already covered.

What this does:
- Filters `sales.orders` to `region = 'west'` rows with `rls_region_west`, grants four columns of `sales.customers`, and masks `sales.payments(card_number)` with `mask_card_last4`, all for `agent_support`.

### 6. Set per-user limits

As a database administrator. Size the limit to the agent's concurrency; driver connections stay open while idle.

```sql
ALTER USER "IAMR:agent-support" SET statement_timeout TO 120000;
ALTER USER "IAMR:agent-support" CONNECTION LIMIT 10 SESSION TIMEOUT 300;
```

Superusers ignore connection limits.

What this does:
- Stops any statement of this user after 120 seconds, allows at most 10 concurrent connections, and ends sessions idle for 300 seconds.

### 7. Configure the agent's tools

Write each tool as one fixed, parameterized statement with a fixed `StatementName` and SQL comment, so the agent chooses only parameters and every query names its tool. Excerpt from the custom MCP server, copied as it is: the SQL constant and the Data API call.

```python
SQL = """/* app=sales-metrics tool=daily_revenue */ SELECT order_date, SUM(total_amount) AS revenue
FROM sales.v_daily_revenue
WHERE region = :region AND order_date BETWEEN :start_date AND :end_date
GROUP BY order_date ORDER BY order_date LIMIT 400"""

    stmt = rsd.execute_statement(
        WorkgroupName="agents-wg", Database="dev", Sql=SQL,
        StatementName="sales-metrics:daily_revenue",  # fixed per tool: CloudTrail and ListStatements name the tool
        Parameters=[{"name": "region", "value": region},
                    {"name": "start_date", "value": start.isoformat()},
                    {"name": "end_date", "value": end.isoformat()}])
```

Full example: [`sales_metrics_mcp.py`](../custom-mcp-server/sales_metrics_mcp.py)

The excerpt reads `sales.v_daily_revenue`, which only the custom MCP server path creates and grants. Point your tool's SQL at objects `agent_support` can read (`sales.orders`, `sales.payments`), and give each tool its own `app=` comment and `StatementName`, for example `/* app=support-agent tool=<tool> */` and `support-agent:<tool>`.

What this does:
- Each tool sends one statement whose text doesn't change; the parameters are passed separately, so the agent can't change the SQL.

### 8. Try it

Invoke the agent with a question that calls one of its tools. As a database administrator, check SYS_QUERY_HISTORY: the tool's statement runs under `IAMR:agent-support` and starts with its `app=` comment.

## Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| SYS_QUERY_HISTORY for `IAMR:agent-support` after an agent invocation | database administrator | the agent's queries, under `IAMR:agent-support`, with each tool's SQL comment |
| SYS_CONNECTION_LOG for `IAMR:agent-support` (driver tools) | database administrator | the tool's connections, with its `application_name` if the tool sets one |
| `SELECT usename, useconnlimit FROM pg_user_info WHERE usename = 'IAMR:agent-support';` | database administrator | `useconnlimit` is `10` |
| Optional: [`idle-sessions.sql`](../../observe/detection/idle-sessions.sql), before and after `StopRuntimeSession` | monitoring role | the tool's held driver sessions are listed before, and gone after the session stops |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| Connections pile up toward the user's `CONNECTION LIMIT` | Driver sessions held open per runtime session or per warm Lambda execution environment | Keep `SESSION TIMEOUT` set (step 6), close connections in the tool, and stop runtime sessions with `StopRuntimeSession` |
| A driver can't connect | No network path from the runtime or the function to the workgroup endpoint | Give the runtime or the function network access to the workgroup's VPC, or use the Data API |
| Queries run as the wrong user | The tool uses the default credentials of another role | Run the tool under the agent's own execution role or function role |
| `permission denied for relation v_daily_revenue` or `relation "sales.v_daily_revenue" does not exist` | The step 7 excerpt was copied as is; `agent_support` has no grant on that view | Point the SQL at `sales.orders` or `sales.payments` |
| `rls policy "rls_region_west" already exists` in step 5 | The file already ran for another path | Nothing to change: the policies attach to `agent_support` |
| `CREATE ROLE agent_support` fails in step 4 because the role already exists | Another path already ran `agent-role.sql` | Run only its last line, `GRANT ROLE agent_support TO "IAMR:agent-support";` |

## Clean up

1. Delete the agent's runtime or its gateway target, and the Lambda function: see [DeleteAgentRuntime](https://docs.aws.amazon.com/bedrock-agentcore-control/latest/APIReference/API_DeleteAgentRuntime.html) and [DeleteGatewayTarget](https://docs.aws.amazon.com/bedrock-agentcore-control/latest/APIReference/API_DeleteGatewayTarget.html) in the AgentCore Control Plane API Reference.
2. As a database administrator in `dev` (the root clean-up order runs the cost-envelope cleanup, which resets this user's settings, before this step):

   ```sql
   REVOKE ROLE agent_support FROM "IAMR:agent-support";
   DROP USER "IAMR:agent-support";
   ```

3. Delete the IAM role. Its inline policies are `agent-data-plane`, plus `agent-denies` if you applied the shared denies as an identity policy; `delete-role` fails with `DeleteConflict` while any policy remains.

   ```bash
   aws iam list-role-policies --role-name agent-support
   aws iam delete-role-policy --role-name agent-support --policy-name agent-data-plane
   aws iam delete-role-policy --role-name agent-support --policy-name agent-denies
   aws iam list-attached-role-policies --role-name agent-support
   aws iam delete-role --role-name agent-support
   ```

   Run `delete-role-policy` once for each name that `list-role-policies` returns. If `list-attached-role-policies` lists a managed policy you attached for the runtime or the function, detach it with `aws iam detach-role-policy --role-name agent-support --policy-arn <policy-arn>` before `delete-role`.
4. Delete the generated trust files:

   ```bash
   cd access-layer/agentcore-custom-agent
   rm -f agent-support-runtime-trust.json agent-support-lambda-trust.json
   ```

5. Then run the data-layer cleanup if no other path still uses `agent_support` or row-level security on `sales.orders`.

## Related

- [Shared controls](../shared/): the data plane policy and the organization-wide deny statements.
- [Data layer](../../data-layer/): `agent_support`, rows, columns and values, and their cleanup.
- More limits: [cost-envelope](../../cost-envelope/)
- Full example: [sales_metrics_mcp.py](../custom-mcp-server/sales_metrics_mcp.py)
- [Observe: detection](../../observe/detection/), including [`idle-sessions.sql`](../../observe/detection/idle-sessions.sql) for held driver sessions.
- [act-refund](../../act-refund/): a scoped action tool for the same agent, with approval above a threshold.
- The other paths: [Redshift MCP Server](../redshift-mcp-server/), [AWS MCP Server](../aws-mcp-server/), [custom MCP server](../custom-mcp-server/), [Bedrock Knowledge Bases](../bedrock-knowledge-base/).
