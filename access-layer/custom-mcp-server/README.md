# Custom MCP server: fixed tools, fixed SQL, one curated view

On this path an application or agent calls an MCP server you write, whose tools each run one fixed, parameterized statement through the Redshift Data API, so the agent chooses only the parameters. It addresses excessive agency (no free-form SQL, one view, its own role) and unbounded consumption (a row limit, a date range limit and per-user limits).
In the accompanying blog post: section "Data plane: a narrow tool surface on every path".

## When to use this path

Use it for production applications and agents that need a fixed set of questions answered, where the agent may choose only parameters such as a region or a date range. The server normally runs next to the application as a local MCP server over stdio, or is hosted; at Amazon Bedrock AgentCore Gateway, [Policy in Amazon Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy.html) can check each tool call. This sample uses stdio. It's normally set up by the team that owns the application, with an IAM administrator for the role and a database administrator for the view and grants.

Use another path if developers need ad hoc SQL in an AI assistant (the `redshift-mcp-server` path), or if the tools run in a custom agent on AgentCore (the `agentcore-custom-agent` path). See [Choose your path](../README.md#choose-your-path).

## How the agent reaches Redshift

The MCP client starts [`sales_metrics_mcp.py`](sales_metrics_mcp.py) over stdio. The server has one tool, `daily_revenue(region, start_date, end_date)`. The tool checks that the region is `west`, `east` or `central` and that the range is at most 90 days, then calls the Data API `ExecuteStatement` with named parameters, the fixed `StatementName` `sales-metrics:daily_revenue`, and SQL that starts with the comment `/* app=sales-metrics tool=daily_revenue */`. The Data API signs in to the workgroup with `redshift-serverless:GetCredentials` as the server's own role.

## Which identity Redshift sees

The server runs under its own role, `agent-sales-metrics` (profile `sales-metrics`), seen as the database user `IAMR:agent-sales-metrics`. The agent never gets credentials of its own: it can only call the tool.

Least privilege needs both scopes: the IAM policy limits which workgroup and which APIs the role can call, and the database permissions of `sales_metrics_tool` allow `SELECT` on one view only.

## Workflow

![Workflow for a custom MCP server. An application or agent calls the daily_revenue tool, which runs one fixed, parameterized statement through the Data API under the server's own role, agent-sales-metrics. Redshift sees IAMR:agent-sales-metrics, whose sales_metrics_tool database role can select only from one curated view. Guardrails: validated parameters, a fixed statement name and SQL comment for attribution, an IAM policy scoped to one workgroup, a statement timeout and row limit, and grants on one view.](../../images/access-path-custom-mcp-server.png)

1. Client: an application or agent with an MCP client that calls `daily_revenue`; the agent chooses only tool parameters.
2. MCP server: the `sales-metrics` server, with one tool and one parameterized statement, a fixed `StatementName` and SQL comment.
3. IAM role and policy: `agent-sales-metrics` with `agent-data-plane-policy.json`.
4. Sign-in and database user: `IAMR:agent-sales-metrics` through the Data API `ExecuteStatement`, with `statement_timeout` on the user and `LIMIT 400` in the SQL.
5. Database role and permissions: `sales_metrics_tool`, with `SELECT` on `sales.v_daily_revenue` only, and row-level security when it's on.
6. Data: `sales.orders` in Redshift managed storage; the base tables stay out of the role's reach.

## Guardrails on this path

| Layer | Guardrail | Where it's set | File or setting |
| --- | --- | --- | --- |
| Agent layer | The agent chooses only tool parameters, never SQL | MCP server | `daily_revenue` in `sales_metrics_mcp.py` |
| Access layer | Parameters checked: region in a fixed set, range at most 90 days; the tool raises an error and sends no statement otherwise | MCP server | `REGIONS` and the range check in `sales_metrics_mcp.py` |
| Access layer | Fixed `StatementName` and SQL comment, so CloudTrail, `ListStatements` and SYS_QUERY_HISTORY name the tool | MCP server | `StatementName="sales-metrics:daily_revenue"` and `/* app=sales-metrics tool=daily_revenue */` |
| Access layer | AgentCore Policy checks each call when the server sits behind AgentCore Gateway | AgentCore Gateway | [Policy in Amazon Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/policy.html) |
| Access layer | SQL on one workgroup; results of the role's own statements only | IAM | [`agent-data-plane-policy.json`](../shared/agent-data-plane-policy.json) |
| Data layer | `SELECT` on one curated view only; row-level security when it's on for `sales.orders` | Redshift | Steps 4 and 5 |
| Cost envelope | `LIMIT 400` in the SQL; `statement_timeout` and `CONNECTION LIMIT` on the user | MCP server, Redshift | `SQL` in `sales_metrics_mcp.py`; step 6 |

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`sales_metrics_mcp.py`](sales_metrics_mcp.py) | The MCP server: one tool, `daily_revenue`, that runs one fixed, parameterized statement against `sales.v_daily_revenue` through the Data API and returns rows of `order_date` and `revenue` | Where the MCP client starts it (step 7); edit `WorkgroupName="agents-wg"` and `Database="dev"` first | runs as `IAMR:agent-sales-metrics` |
| [`requirements.txt`](requirements.txt) | Dependencies: `mcp>=1,<2` (FastMCP ships only in the MCP Python SDK 1.x) and `boto3` | `pip install -r requirements.txt` (step 7) | none (dependency list) |

## Prerequisites

- An Amazon Redshift Serverless workgroup for agents, and the example table `sales.orders` with the columns `region`, `order_date` and `total_amount` (see the root README).
- AWS CLI v2 and Python 3.10 or later.
- An IAM administrator for steps 1 and 2, and a database administrator for steps 4 to 6. The SQL on this page runs in database `dev`, the database that `sales_metrics_mcp.py` names.
- Your own AWS CLI profile (`developer` in the examples) that may assume the server's role.

Database identity on this path:

| IAM role | Database user | Database role | Where the grants come from | Row-level security and masking |
| --- | --- | --- | --- | --- |
| `agent-sales-metrics` (profile `sales-metrics`) | `IAMR:agent-sales-metrics` | `sales_metrics_tool` | Step 4: the view, the role and its grants, in this README | Step 5: `rls_sales_metrics_regions` attached to `sales_metrics_tool` when row-level security is on for `sales.orders` |

Placeholders in this path:
- `<developer-role>`: the IAM role behind your `developer` profile.
- `<agent-workgroup>` and `<agent-workgroup-id>`: the agent workgroup's name (`agents-wg` in `sales_metrics_mcp.py`) and ID.
- `<repo-path>`: the absolute path of your clone of this repository.
- `<id>`: the statement ID that `execute-statement` returns.
- `111122223333` and `us-east-1`: the example account ID and Region. Replace them with yours.

## Set up

Run each block from the repository root; each one starts with the `cd` it needs.

### 1. Create the IAM role

```bash
cd access-layer/custom-mcp-server
cat > agent-sales-metrics-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "DeveloperAssumesAgentRole", "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::111122223333:role/<developer-role>" },
      "Action": "sts:AssumeRole" }
  ]
}
EOF
aws accessanalyzer validate-policy --policy-type RESOURCE_POLICY \
  --validate-policy-resource-type AWS::IAM::AssumeRolePolicyDocument \
  --policy-document file://agent-sales-metrics-trust.json --query "findings[?findingType=='ERROR']"
aws iam create-role --role-name agent-sales-metrics \
  --assume-role-policy-document file://agent-sales-metrics-trust.json
```

What this does:
- Writes the generated trust file `agent-sales-metrics-trust.json` in this folder (don't commit it), checks it (`[]` means no errors) and creates the role `agent-sales-metrics`. For a hosted server, trust the service that runs it instead of your developer role.

### 2. Attach the policy

Replace `111122223333`, `us-east-1` and `<agent-workgroup-id>` in `../shared/agent-data-plane-policy.json` first, and attach it with `file://` so the shell doesn't rewrite `${aws:userid}`.

```bash
cd access-layer/custom-mcp-server
aws iam put-role-policy --role-name agent-sales-metrics --policy-name agent-data-plane \
  --policy-document file://../shared/agent-data-plane-policy.json
```

Optional, so the tool's owner can list its statements by name: add the `ListOwnStatements` statement (the same statement `observe/attribution/data-api-statement-events.md` documents) as a second inline policy.

```bash
cd access-layer/custom-mcp-server
aws iam put-role-policy --role-name agent-sales-metrics --policy-name list-own-statements \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"ListOwnStatements","Effect":"Allow","Action":"redshift-data:ListStatements","Resource":"*"}]}'
aws iam get-role-policy --role-name agent-sales-metrics --policy-name list-own-statements
```

Inline JSON is safe here because this statement has no `${...}` policy variable; the policy files that use `${aws:userid}` are always attached with `file://`.

What this does:
- Adds the inline policy `agent-data-plane`: list workgroups, sign in and run SQL on one workgroup, and read only the results of the role's own statements.
- Optionally adds `list-own-statements`. `ListStatements` has no resource-level permissions or statement owner, which is why `Resource` is `*`; the Data API still returns only statements run by the caller's own role.

### 3. Create the database user

Add the profile to `~/.aws/config`:

```ini
[profile sales-metrics]
role_arn = arn:aws:iam::111122223333:role/agent-sales-metrics
source_profile = developer
duration_seconds = 3600
```

Then sign in once through the Data API, which creates the database user:

```bash
cd access-layer/custom-mcp-server
aws redshift-data execute-statement --workgroup-name <agent-workgroup> --database dev \
  --sql "SELECT current_user" --profile sales-metrics --region us-east-1
aws redshift-data describe-statement --id <id> --profile sales-metrics --region us-east-1 --query Status
aws redshift-data get-statement-result --id <id> --profile sales-metrics --region us-east-1 \
  --query "Records[0][0].stringValue"
```

What this does:
- The profile assumes `agent-sales-metrics` from your `developer` profile; role chaining caps each session at 1 hour.
- Run `describe-statement` until it shows `"FINISHED"`; `get-statement-result` returns `"IAMR:agent-sales-metrics"`. This first sign-in creates the database user, with no privileges yet.

### 4. Grant database permissions

As a database administrator in `dev`, create the curated view, the tool's database role and its grants:

```sql
CREATE VIEW sales.v_daily_revenue AS SELECT region, order_date, total_amount FROM sales.orders;
CREATE ROLE sales_metrics_tool;
GRANT USAGE ON SCHEMA sales TO ROLE sales_metrics_tool;
GRANT SELECT ON sales.v_daily_revenue TO ROLE sales_metrics_tool;
GRANT ROLE sales_metrics_tool TO "IAMR:agent-sales-metrics";
```

What this does:
- Creates `sales.v_daily_revenue` with only the three columns the tool reads.
- Creates `sales_metrics_tool` with `USAGE` on `sales` and `SELECT` on the view only, and grants it to `IAMR:agent-sales-metrics`. The header comment of `sales_metrics_mcp.py` asks for `SELECT` on `sales.v_daily_revenue` only; this role-based grant gives the user exactly that privilege.

### 5. Add row-level security and masking

Only if row-level security is on for `sales.orders`, for example after [`fine-grained-access.sql`](../../data-layer/fine-grained-access.sql):

> [!WARNING]
> While row-level security is on for `sales.orders` and no policy is attached to `sales_metrics_tool`, the tool returns no rows.

```sql
CREATE RLS POLICY rls_sales_metrics_regions WITH (region VARCHAR(16)) USING (region IN ('west', 'east', 'central'));
ATTACH RLS POLICY rls_sales_metrics_regions ON sales.orders TO ROLE sales_metrics_tool;
```

What this does:
- Lets `sales_metrics_tool` see the rows of the three regions the tool accepts. No masking is needed: the view has no sensitive columns.

### 6. Set per-user limits

As a database administrator:

```sql
ALTER USER "IAMR:agent-sales-metrics" SET statement_timeout TO 120000;
ALTER USER "IAMR:agent-sales-metrics" CONNECTION LIMIT 10 SESSION TIMEOUT 300;
```

Superusers ignore connection limits.

What this does:
- Stops any statement of this user after 120 seconds, allows at most 10 concurrent connections, and ends sessions idle for 300 seconds.

### 7. Configure the MCP client

Edit `WorkgroupName="agents-wg"` and `Database="dev"` in `sales_metrics_mcp.py` to your workgroup and database, then install the dependencies with the same Python the client will run:

```bash
cd access-layer/custom-mcp-server
pip install -r requirements.txt
```

Or use `uv pip install -r requirements.txt`. Then add the server to the MCP client's configuration, for example `~/.kiro/settings/mcp.json` in Kiro, with the absolute path of the file:

```json
{
  "mcpServers": {
    "sales-metrics": {
      "command": "python",
      "args": ["<repo-path>/access-layer/custom-mcp-server/sales_metrics_mcp.py"],
      "env": { "AWS_PROFILE": "sales-metrics", "AWS_DEFAULT_REGION": "us-east-1" }
    }
  }
}
```

What this does:
- The client starts the server over stdio under the `sales-metrics` profile.
- `boto3.client("redshift-data")` is created when the module loads and takes its Region from `AWS_DEFAULT_REGION` (or the profile's `region`). boto3 doesn't read `AWS_REGION` on your machine, so `AWS_REGION` alone isn't enough. Without either, the server stops at startup with `NoRegionError: You must specify a region.`

### 8. Try it

Restart the MCP client and ask it to call `daily_revenue` with `region` `west` and a range of up to 90 days.

## Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| `aws sts get-caller-identity --profile sales-metrics` | developer | `arn:aws:sts::111122223333:assumed-role/agent-sales-metrics/...` |
| Call `daily_revenue` with `region` `west` and a range of up to 90 days | the MCP client | rows of `order_date` and `revenue` |
| Call `daily_revenue` with a region outside `west`, `east` and `central` | the MCP client | the tool's error `region must be west, east, or central, and the range at most 90 days`; no statement is sent |
| SYS_QUERY_HISTORY for `IAMR:agent-sales-metrics` | database administrator | `/* app=sales-metrics tool=daily_revenue */ SELECT ... $1 ... $2 ... $3` under `IAMR:agent-sales-metrics` |
| `aws redshift-data execute-statement --workgroup-name <agent-workgroup> --database dev --sql "SELECT * FROM sales.orders LIMIT 1" --profile sales-metrics --region us-east-1`, then `describe-statement` | server's role | `FAILED` with `permission denied` |
| `SELECT usename, useconnlimit FROM pg_user_info WHERE usename = 'IAMR:agent-sales-metrics';` | database administrator | `useconnlimit` is `10` |
| Optional: `aws redshift-data list-statements --statement-name sales-metrics --profile sales-metrics --region us-east-1`, and CloudTrail `ExecuteStatement` events | server's role (needs the `list-own-statements` policy from step 2) | the statement name `sales-metrics:daily_revenue`; CloudTrail events carry `requestParameters.statementName` |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `region must be west, east, or central, and the range at most 90 days` | Input outside the tool's limits, by design | Call the tool with a region in the set and a range of 90 days or less |
| `list-statements` fails with AccessDenied | The `list-own-statements` inline policy from step 2 isn't attached | Run the optional block in step 2 |
| `DeleteConflict` from `delete-role` during cleanup | An inline policy such as `list-own-statements` is still attached | List the inline policies and delete each one first (Clean up step 3) |
| `permission denied for relation v_daily_revenue` | The role or its grant is missing, or the role wasn't granted to the user | Run step 4 again |
| No rows while row-level security is on for `sales.orders` | No row-level security policy is attached to `sales_metrics_tool` | Run step 5 |
| `NoRegionError: You must specify a region.` at startup | No `AWS_DEFAULT_REGION` in the server's `env` and no `region` in the profile. boto3 doesn't read `AWS_REGION` on your machine | Add `AWS_DEFAULT_REGION` to the client configuration (step 7), or `region` to the `sales-metrics` profile |
| `ModuleNotFoundError` or `ImportError` for `mcp.server.fastmcp` | The MCP Python SDK 2.x, or no SDK, is installed for the Python the client runs | `pip install -r requirements.txt` with that Python |
| `AccessDenied` calling `AssumeRole` with the `sales-metrics` profile | The trust policy's principal isn't your developer role's full ARN. For IAM Identity Center roles that ARN includes the `aws-reserved/sso.amazonaws.com/` path, followed by the Region of your IAM Identity Center instance unless it's `us-east-1`, as in `arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/eu-west-2/AWSReservedSSO_<permission-set>_<suffix>` | `aws sts get-caller-identity --profile developer` shows the role name in its assumed-role session ARN, which has no path. `aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ --query "Roles[].Arn"` shows the full role ARN to put in the trust policy |

## Clean up

1. Remove the `sales-metrics` entry from the MCP client configuration.
2. As a database administrator in `dev` (run the first two statements only if you created the row-level security policy in step 5):

   ```sql
   DETACH RLS POLICY rls_sales_metrics_regions ON sales.orders FROM ROLE sales_metrics_tool;
   DROP RLS POLICY rls_sales_metrics_regions;
   REVOKE ROLE sales_metrics_tool FROM "IAMR:agent-sales-metrics";
   DROP VIEW sales.v_daily_revenue;
   REVOKE USAGE ON SCHEMA sales FROM ROLE sales_metrics_tool;
   DROP ROLE sales_metrics_tool;
   DROP USER "IAMR:agent-sales-metrics";
   ```

3. Delete the IAM role. Its inline policies are `agent-data-plane` and, if you added it, `list-own-statements`; `delete-role` fails with `DeleteConflict` while an inline policy remains.

   ```bash
   aws iam list-role-policies --role-name agent-sales-metrics
   aws iam delete-role-policy --role-name agent-sales-metrics --policy-name agent-data-plane
   aws iam delete-role-policy --role-name agent-sales-metrics --policy-name list-own-statements
   aws iam list-attached-role-policies --role-name agent-sales-metrics
   aws iam delete-role --role-name agent-sales-metrics
   ```

   Run `delete-role-policy` once for each name that `list-role-policies` returns; `list-attached-role-policies` is expected to return an empty list.
4. Remove the `[profile sales-metrics]` block from `~/.aws/config`, and delete the generated trust file:

   ```bash
   cd access-layer/custom-mcp-server
   rm agent-sales-metrics-trust.json
   ```

5. Then run the data-layer cleanup if no other path still uses `agent_support` or row-level security on `sales.orders`.

## Related

- [Shared controls](../shared/): the data plane policy.
- [Data layer](../../data-layer/): row-level security on `sales.orders` and the other data controls.
- More limits: [cost-envelope](../../cost-envelope/)
- [Observe: attribution](../../observe/attribution/), including [`data-api-statement-events.md`](../../observe/attribution/data-api-statement-events.md): statement names, the `ListOwnStatements` statement and status events for each tool call.
- [act-refund](../../act-refund/): a scoped write tool next to this read tool, with approval above a threshold.
- [AgentCore custom agent](../agentcore-custom-agent/): the same fixed-SQL pattern for tools that run in AgentCore Runtime or behind AgentCore Gateway.
