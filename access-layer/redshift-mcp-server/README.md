# Redshift MCP Server: read-only SQL from an AI assistant, as the agent's own role

On this path an AI assistant such as Kiro runs SQL through the open-source Amazon Redshift MCP Server, signed in as a dedicated agent role instead of the developer's own. It addresses excessive agency (read-only mode, one workgroup, a database role with narrow grants) and unbounded consumption (per-user timeouts and connection limits).
In the accompanying blog post: section "Data plane: a narrow tool surface on every path".

## When to use this path

Use it when developers and analysts ask questions about Redshift data in AI assistants such as Kiro, or any MCP-compatible client, with the [Amazon Redshift MCP Server](https://github.com/awslabs/mcp/tree/main/src/redshift-mcp-server) running on their own machine. It's normally set up by a platform or data team: an IAM administrator creates the agent role, a database administrator grants its database role, and each developer adds the profile and the client configuration.

Use another path if the assistant reaches AWS through the managed AWS MCP Server (the `aws-mcp-server` path), or if a production application needs a fixed set of questions answered (the `custom-mcp-server` path). See [Choose your path](../README.md#choose-your-path).

## How the agent reaches Redshift

The assistant starts the Redshift MCP Server on your machine over stdio. The server calls the Redshift Data API with the `redshift-agent` AWS CLI profile, so every call is signed as the agent role `agent-redshift-readonly`, and the Data API signs in to the workgroup with `redshift-serverless:GetCredentials`. In read-only mode, the default, nothing a query changes is kept. The server starts a `BEGIN READ ONLY` transaction for each statement, so a query returns its rows, and Redshift refuses a statement that would change data with `ERROR: transaction is read-only`. The server then ends the transaction without committing it. The server's statement guard also refuses statement types a read-only transaction can't stop, such as `UNLOAD`, `GRANT`, `CALL` and `SET`.

The data plane policy allows `redshift-data:BatchExecuteStatement`, which version 0.1.2 of the server needs before it can run writes or named transactions. Without that action, the server stays read-only: it runs reads one statement at a time with `ExecuteStatement` and refuses writes and named transactions. Those reads don't run in a `BEGIN READ ONLY` transaction, so the server, not a read-only transaction, refuses writes, and the database grants still apply. With it, writes still need `ACCESS_MODE=read-write` in the MCP client configuration, which is off by default and stays off on this path, and the agent's database grants still limit what any write can change. Source: the server's README for [version 0.1.2](https://pypi.org/project/awslabs.redshift-mcp-server/0.1.2/).

## Which identity Redshift sees

Redshift sees the role in the profile, `agent-redshift-readonly`, as the database user `IAMR:agent-redshift-readonly`. Without a dedicated profile, the assistant and the server run as the developer's own role (for example `IAMR:DataPlatformAdmin`) with that role's grants.

Least privilege needs both scopes: the IAM policy limits which workgroup and which APIs the role can call, and the database permissions of `agent_support` limit what its SQL can read.

## Workflow

![Workflow for the Amazon Redshift MCP Server path. An AI assistant starts the Redshift MCP Server, which signs in with the agent-redshift-readonly role from a dedicated profile. Redshift maps it to the database user IAMR:agent-redshift-readonly, whose database role grants, row-level security and masking decide the data it reads. Guardrails: tool allow lists in the assistant, with approval kept for consequential or above-threshold writes, read-only mode in the server, an IAM policy scoped to one workgroup, per-user timeouts and connection limits, and Lake Formation permissions on Iceberg tables.](../../images/access-path-redshift-mcp-server.png)

1. Client: an AI assistant such as Kiro, or any MCP-compatible client, with tool allow lists.
2. MCP server: the Redshift MCP Server, running locally and read-only by default.
3. IAM role and policy: `agent-redshift-readonly` with `agent-data-plane-policy.json`, used through the `redshift-agent` profile.
4. Sign-in and database user: the Data API signs in with `GetCredentials` as `IAMR:agent-redshift-readonly`, with `statement_timeout` and `CONNECTION LIMIT` set on the user.
5. Database role and permissions: `agent_support`, with its grants, row-level security and masking.
6. Data: Redshift managed storage, or Apache Iceberg tables governed by Lake Formation permissions.

## Guardrails on this path

| Layer | Guardrail | Where it's set | File or setting |
| --- | --- | --- | --- |
| Agent layer | Tool allow lists in the assistant, with approval for consequential or above-threshold writes. This path is read-only, so no call needs approval | AI assistant | The assistant's tool settings; optional `redshift-guide` skill from the Agent Toolkit for AWS (step 7) |
| Access layer | Read-only mode: nothing a query changes is kept. Each statement runs in its own `BEGIN READ ONLY` transaction, and a statement guard refuses types such as `UNLOAD`, `GRANT` and `SET` | Redshift MCP Server | `ACCESS_MODE` left unset (defaults to `read-only`) |
| Access layer | Result size cap: a result larger than the cap is refused rather than cut short | Redshift MCP Server | `MAX_RESULT_ROWS`, 1,000 by default in version 0.1.2 |
| Access layer | Dedicated agent profile, not the developer's own role | Developer's machine | `redshift-agent` profile from [`aws-config-example.ini`](../shared/aws-config-example.ini) |
| Access layer | SQL on one workgroup; results of the role's own statements only | IAM | `RunSqlOnOneWorkgroup` and `ReadOwnStatements` in [`agent-data-plane-policy.json`](../shared/agent-data-plane-policy.json) |
| Data layer | Grants on one database role, row-level security, column privileges, masking, metadata security | Redshift | [`agent-role.sql`](../../data-layer/agent-role.sql), [`fine-grained-access.sql`](../../data-layer/fine-grained-access.sql), [`metadata-security.sql`](../../data-layer/metadata-security.sql) |
| Cost envelope | `statement_timeout` and `CONNECTION LIMIT` on the agent's database user | Redshift | Step 6 |
| Cost envelope | Workgroup max capacity and daily usage limit | Redshift Serverless | `cost-envelope/serverless-ceilings.sh` (see Related) |

## Files

This folder has no files; set up uses the linked files below: [`../shared/agent-data-plane-policy.json`](../shared/agent-data-plane-policy.json), [`../shared/aws-config-example.ini`](../shared/aws-config-example.ini), [`../../data-layer/agent-role.sql`](../../data-layer/agent-role.sql), [`../../data-layer/redshiftdbroles-tag.sh`](../../data-layer/redshiftdbroles-tag.sh) (quoted lines only) and [`../../data-layer/fine-grained-access.sql`](../../data-layer/fine-grained-access.sql).

## Prerequisites

- An Amazon Redshift Serverless workgroup for agents, and the example schema `sales.orders`, `sales.customers` and `sales.payments` (see the root README).
- AWS CLI v2, and `uv` with Python 3.10 or later, so the MCP client can start the server with `uvx`.
- An IAM administrator for steps 1 and 2, and a database administrator (superuser, or a user with `sys:secadmin` for the row-level security and masking statements) for steps 4 to 6. The SQL on this page runs in database `dev`.
- Your own AWS CLI profile (`developer` in the examples) that may assume the agent role.

Database identity on this path:

| IAM role | Database user | Database role | Where the grants come from | Row-level security and masking |
| --- | --- | --- | --- | --- |
| `agent-redshift-readonly` (profile `redshift-agent`) | `IAMR:agent-redshift-readonly` | `agent_support` | Step 4a creates `agent_support` and its grants from `agent-role.sql` without its last line (skip it if another path already ran it). Step 4b gives the role to the user with `GRANT ROLE` or the `RedshiftDbRoles` tag | Step 5: `fine-grained-access.sql` as is; its policies attach to `agent_support` |

Placeholders in this path:
- `<developer-role>`: the IAM role behind your `developer` profile, which the agent role trusts.
- `<agent-workgroup>`: the name of the agent workgroup, for example `agents-wg`.
- `<agent-workgroup-id>`: its workgroup ID, in `agent-data-plane-policy.json`.
- `<id>`: the statement ID that `execute-statement` returns.
- `111122223333` and `us-east-1`: the example account ID and Region. Replace them with yours, including inside `agent-data-plane-policy.json` and `aws-config-example.ini`.

## Set up

Run each block from the repository root; each one starts with the `cd` it needs.

### 1. Create the IAM role

Write the trust policy that lets your developer role assume the agent role, check it, and create the role:

```bash
cd access-layer/redshift-mcp-server
cat > agent-redshift-readonly-trust.json << 'EOF'
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
  --policy-document file://agent-redshift-readonly-trust.json --query "findings[?findingType=='ERROR']"
aws iam create-role --role-name agent-redshift-readonly \
  --assume-role-policy-document file://agent-redshift-readonly-trust.json
```

What this does:
- Writes `agent-redshift-readonly-trust.json` in this folder. It's a generated file: don't commit it.
- `validate-policy` returns `[]` when the trust policy has no errors.
- Creates the role `agent-redshift-readonly`, which only your developer role can assume. For an IAM Identity Center role, the principal is the role's full ARN, including its path (see Common errors).

### 2. Attach the policy

Replace `111122223333`, `us-east-1` and `<agent-workgroup-id>` in `../shared/agent-data-plane-policy.json` first.

> [!WARNING]
> Attach the policy with `file://`. Pasting the JSON into a shell can rewrite `${aws:userid}`.

```bash
cd access-layer/redshift-mcp-server
aws iam put-role-policy --role-name agent-redshift-readonly --policy-name agent-data-plane \
  --policy-document file://../shared/agent-data-plane-policy.json
aws iam get-role-policy --role-name agent-redshift-readonly --policy-name agent-data-plane
```

What this does:
- Adds the inline policy `agent-data-plane`: list workgroups, sign in and run SQL on one workgroup, and read only the results of the role's own statements.
- For the organization-wide deny statements, see [shared controls](../shared/). They act only on requests through AWS managed MCP servers, not on this server.

### 3. Create the database user

Add the `redshift-agent` profile unless it already exists, then sign in once through the Data API. The first sign-in creates the database user.

```bash
cd access-layer/redshift-mcp-server
aws configure list-profiles | grep -qx redshift-agent || cat ../shared/aws-config-example.ini >> ~/.aws/config
aws redshift-data execute-statement --workgroup-name <agent-workgroup> --database dev \
  --sql "SELECT current_user" --profile redshift-agent --region us-east-1
aws redshift-data describe-statement --id <id> --profile redshift-agent --region us-east-1 --query Status
aws redshift-data get-statement-result --id <id> --profile redshift-agent --region us-east-1 \
  --query "Records[0][0].stringValue"
```

What this does:
- Adds `[profile redshift-agent]` to `~/.aws/config` (edit the account ID and `source_profile` in the file first). It skips the append when `aws configure list-profiles` already lists `redshift-agent`, for example after the shared controls README: a second block makes every AWS CLI command fail.
- `execute-statement` returns an `Id`. Run `describe-statement` until it shows `"FINISHED"`; `get-statement-result` then returns `"IAMR:agent-redshift-readonly"`.
- Redshift creates the database user `IAMR:agent-redshift-readonly` at this first sign-in. It has no privileges yet.

### 4. Grant database permissions

Two parts: create the database role (4a), then give it to the agent's user (4b). Both run in database `dev`.

### 4a. Create the agent_support role

As a database administrator, run lines 1 to 4 of [`agent-role.sql`](../../data-layer/agent-role.sql), without its last line (`GRANT ROLE agent_support TO "IAMR:agent-support";`). Skip this step if another path already ran it.

```sql
-- One database role per agent: privileges go to the role, never to the user
CREATE ROLE agent_support;
GRANT USAGE ON SCHEMA sales TO ROLE agent_support;
GRANT SELECT ON sales.orders, sales.payments TO ROLE agent_support;
```

What this does:
- Creates the database role `agent_support` with `USAGE` on schema `sales` and `SELECT` on `sales.orders` and `sales.payments`.

### 4b. Give the role to the agent user

Use one of two variants.

Variant A, as a database administrator:

```sql
GRANT ROLE agent_support TO "IAMR:agent-redshift-readonly";
```

Variant B, as an IAM administrator, with the `RedshiftDbRoles` tag on the IAM role. Lines under the tag and permissions comments of `redshiftdbroles-tag.sh`, quoted as written; replace `<agent-role-name>` with `agent-redshift-readonly` after you copy them.

```bash
cd data-layer
aws iam tag-role --role-name <agent-role-name> \
  --tags Key=RedshiftDbRoles,Value=agent_support
aws iam put-role-policy --role-name <agent-role-name> \
  --policy-name redshiftdbroles-tag-read \
  --policy-document file://redshiftdbroles-tag-permissions.json
```

Then sign in again with the three `redshift-data` commands from step 3: the tag is read at sign-in. The tag only maps the IAM role to `agent_support` at sign-in; it doesn't create the role, so 4a is still required.

What this does:
- Variant A grants `agent_support` to the user, stored as a grant in the database.
- Variant B maps the IAM role to `agent_support` for each session that signs in while the tag is set. Nothing is stored as a grant, so `SHOW GRANTS` for the user doesn't list it; audit it with `aws iam list-role-tags --role-name agent-redshift-readonly`.

### 5. Add row-level security and masking

As a database administrator, run [`fine-grained-access.sql`](../../data-layer/fine-grained-access.sql) as is. Skip this step if you already ran the file for another path; the policies attach to `agent_support`, so every user that holds the role is already covered.

What this does:
- Creates the row-level security policy `rls_region_west` (only `region = 'west'` rows of `sales.orders`), attaches it to `agent_support` and turns row-level security on for `sales.orders`.
- Grants `agent_support` only four columns of `sales.customers`.
- Creates the masking policy `mask_card_last4` and attaches it to `sales.payments(card_number)` for `agent_support`.

### 6. Set per-user limits

As a database administrator:

```sql
ALTER USER "IAMR:agent-redshift-readonly" SET statement_timeout TO 120000;
ALTER USER "IAMR:agent-redshift-readonly" CONNECTION LIMIT 10 SESSION TIMEOUT 300;
```

Superusers ignore connection limits.

What this does:
- Stops any statement of this user after 120 seconds.
- Allows at most 10 concurrent connections for the user, and ends sessions idle for 300 seconds.

### 7. Configure the MCP client

Add the server to your MCP client's configuration, for example `~/.kiro/settings/mcp.json` in Kiro. Other MCP-compatible clients use the same `mcpServers` entry.

```json
{
  "mcpServers": {
    "awslabs.redshift-mcp-server": {
      "command": "uvx",
      "args": ["awslabs.redshift-mcp-server@0.1.2"],
      "env": {
        "AWS_PROFILE": "redshift-agent",
        "AWS_REGION": "us-east-1",
        "LOG_LEVEL": "WARNING"
      }
    }
  }
}
```

What this does:
- Pins the server to version 0.1.2, which this page describes, and runs it with the `redshift-agent` profile.
- Leaves `ACCESS_MODE` unset, so the server runs in read-only mode. Any value other than `read-write` also falls back to read-only.

Optional: with AWS CLI 2.35.0 or later, `aws configure agent-toolkit` sets up the Agent Toolkit for AWS in the AI assistants it detects, and `aws agent-toolkit add-skill --skill-name redshift-guide` adds the `redshift-guide` skill. See [AWS CLI](https://docs.aws.amazon.com/agent-toolkit/latest/userguide/aws-cli.html) in the Agent Toolkit for AWS User Guide.

### 8. Try it

Restart the MCP client and ask the assistant: "Which database user are you connected as on `<agent-workgroup>`?" The server runs `SELECT current_user` and the answer is `IAMR:agent-redshift-readonly`.

## Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| `SELECT current_user` through the server's `execute_query` tool | the assistant | `IAMR:agent-redshift-readonly` |
| `CREATE TABLE public.probe (a INT)` through `execute_query` | the assistant | `ERROR: transaction is read-only`; nothing is created |
| `SET query_group TO 'x'` through `execute_query` | the assistant | `Statement type not allowed in read-only mode: SET` |
| SYS_QUERY_HISTORY for `IAMR:agent-redshift-readonly` | database administrator | the agent's statements, each in its own transaction that starts with `BEGIN READ ONLY` and keeps no changes |
| `SELECT usename, useconnlimit FROM pg_user_info WHERE usename = 'IAMR:agent-redshift-readonly';` | database administrator | `useconnlimit` is `10` |
| Optional: [`shadow-agents.sql`](../../observe/detection/shadow-agents.sql) | monitoring role | lists `IAMR:agent-redshift-readonly` with `registered_agent` true |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `Writes need redshift-data:BatchExecuteStatement, which was denied to the current credentials ...` (or the same message for named transactions) | The role's policy doesn't allow `BatchExecuteStatement`, so the server keeps the read-only behavior of earlier versions: reads work, writes and named transactions are refused | Nothing to fix for reads on this read-only path. For named transactions, attach `agent-data-plane-policy.json` again (step 2); its `RunSqlOnOneWorkgroup` statement allows the action |
| `permission denied for schema sales` | The user holds no role with `USAGE` on `sales`: the `GRANT ROLE` in step 4b is missing, or the `RedshiftDbRoles` tag was removed (the tag is read at sign-in) | Run step 4b again, then sign in again |
| `permission denied for schema sales` after tagging in step 4b, variant B | `agent_support` doesn't exist in the database because step 4a was skipped, or the agent hasn't signed in again since the tag change | Run step 4a, then sign in again |
| AccessDenied on `redshift-data:ExecuteStatement` for another workgroup | Expected: the policy allows SQL on one workgroup | Use the agent workgroup |
| `list_clusters` shows no provisioned clusters | `Discover` covers Redshift Serverless only | For provisioned clusters, add `redshift:DescribeClusters` and `redshift:GetClusterCredentialsWithIAM` to the policy (see [shared controls](../shared/)) |
| `rls policy "rls_region_west" already exists` in step 5 | The file already ran for another path | Nothing to change: the policies attach to `agent_support` |
| `AccessDenied` calling `AssumeRole` with the `redshift-agent` profile | The trust policy's principal isn't your developer role's full ARN. For IAM Identity Center roles that ARN includes the `aws-reserved/sso.amazonaws.com/` path, followed by the Region of your IAM Identity Center instance unless it's `us-east-1`, as in `arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/eu-west-2/AWSReservedSSO_<permission-set>_<suffix>` | `aws sts get-caller-identity --profile developer` shows the role name in its assumed-role session ARN, which has no path. `aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ --query "Roles[].Arn"` shows the full role ARN to put in the trust policy; update it with `aws iam update-assume-role-policy` |
| Every AWS CLI command fails with `Unable to parse config file` | `~/.aws/config` has two `[profile redshift-agent]` blocks, because the profile was appended twice | Delete one of the two blocks |

## Clean up

If the AWS MCP Server path still uses this role and user, run only step 1 and the `rm` block of step 4: the AWS MCP Server cleanup deletes the role and the profile, but not the trust file in this folder.

1. Remove the `awslabs.redshift-mcp-server` entry from the MCP client configuration.
2. As a database administrator in `dev` (skip the `REVOKE` if you used the `RedshiftDbRoles` tag: there's no grant to revoke):

   ```sql
   REVOKE ROLE agent_support FROM "IAMR:agent-redshift-readonly";
   DROP USER "IAMR:agent-redshift-readonly";
   ```

3. Delete the IAM role. `delete-role` fails with `DeleteConflict` while the role has any policy, so list and delete its inline policies first. They may be `agent-data-plane`, plus `agent-denies` if you applied the shared denies as an identity policy, plus `redshiftdbroles-tag-read` if you used the `RedshiftDbRoles` tag. Tags are deleted with the role.

   ```bash
   aws iam list-role-policies --role-name agent-redshift-readonly
   aws iam delete-role-policy --role-name agent-redshift-readonly --policy-name agent-data-plane
   aws iam delete-role-policy --role-name agent-redshift-readonly --policy-name agent-denies
   aws iam delete-role-policy --role-name agent-redshift-readonly --policy-name redshiftdbroles-tag-read
   aws iam list-attached-role-policies --role-name agent-redshift-readonly
   aws iam delete-role --role-name agent-redshift-readonly
   ```

   Run `delete-role-policy` once for each name that `list-role-policies` returns. `list-attached-role-policies` is expected to return an empty list.
4. Remove the `[profile redshift-agent]` block from `~/.aws/config`, and delete the generated trust file:

   ```bash
   cd access-layer/redshift-mcp-server
   rm agent-redshift-readonly-trust.json
   ```

5. Then run the data-layer cleanup if no other path still uses `agent_support` or row-level security on `sales.orders`.

## Related

- [Shared controls](../shared/): the data plane policy, the organization-wide deny statements and the profile.
- [Data layer](../../data-layer/): database identity and roles, the `RedshiftDbRoles` tag, rows, columns and values, and their cleanup.
- More limits: [cost-envelope](../../cost-envelope/)
- [Observe: attribution](../../observe/attribution/) and [detection](../../observe/detection/): which client ran each query, and agents without their own identity.
- The other paths: [AWS MCP Server](../aws-mcp-server/), [custom MCP server](../custom-mcp-server/), [AgentCore custom agent](../agentcore-custom-agent/), [Bedrock Knowledge Bases](../bedrock-knowledge-base/).
