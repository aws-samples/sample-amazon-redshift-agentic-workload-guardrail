# AWS MCP Server: scope the credentials the managed server acts with

On this path an AI assistant reaches AWS through the managed AWS MCP Server and the MCP Proxy for AWS, and runs SQL with the Redshift Data API as a dedicated agent role. Its `aws___run_script` tool can call any AWS API the credentials allow, so this path addresses excessive agency with the credentials themselves (a scoped role, deny statements on `aws:ViaAWSMCPService`, a database role with narrow grants) and unbounded consumption with per-user limits.
In the accompanying blog post: section "Data plane: a narrow tool surface on every path".

## When to use this path

Use it when developers and analysts work in AI assistants such as Kiro that connect to the managed AWS MCP Server through the MCP Proxy for AWS, which signs each request with an AWS CLI profile. It's normally set up by a platform team: an IAM or AWS Organizations administrator creates the agent role and the deny statements, an administrator tags the agent workgroups, a database administrator grants the database role, and each developer adds the profile and the proxy configuration.

Use another path if the assistant runs the open-source Amazon Redshift MCP Server locally (the `redshift-mcp-server` path), or if a production application needs a fixed set of questions answered (the `custom-mcp-server` path). See [Choose your path](../README.md#choose-your-path).

## How the agent reaches Redshift

The assistant starts the MCP Proxy for AWS on your machine. The proxy signs each request with the `redshift-agent` profile and sends it to the AWS MCP Server endpoint. The server's `aws___run_script` tool runs Python with AWS API access, and each Redshift Data API call it makes is forwarded to the Data API under the agent role, with the condition keys `aws:ViaAWSMCPService` (`true`) and `aws:CalledViaAWSMCP` (`aws-mcp.amazonaws.com`) added. The Data API signs in to the workgroup with `redshift-serverless:GetCredentials`. CloudTrail records each tool call as an event with event source `aws-mcp.amazonaws.com` ([Logging AWS MCP Server API calls using AWS CloudTrail](https://docs.aws.amazon.com/agent-toolkit/latest/userguide/logging-using-cloudtrail.html)), and the Data API calls under the agent role.

## Which identity Redshift sees

This path uses the `redshift-agent` profile from [`aws-config-example.ini`](../shared/aws-config-example.ini) and the role `agent-redshift-readonly`, seen as the database user `IAMR:agent-redshift-readonly`: the same role and user as the Redshift MCP Server path. If both servers run side by side and need different permissions, create a separate role and profile and repeat steps 1 to 6 with that name. With an administrator profile, every script the server runs has administrator access.

AWS MCP Server defines no IAM actions of its own: the downstream service authorizes each request with the caller's own IAM policies, with `aws:ViaAWSMCPService` and `aws:CalledViaAWSMCP` added. The preview actions `aws-mcp:InvokeMcp`, `aws-mcp:CallReadOnlyTool` and `aws-mcp:CallReadWriteTool` are no longer required and have no effect. Source: [How AWS MCP Server works with IAM](https://docs.aws.amazon.com/aws-mcp/latest/userguide/security_iam_service-with-iam.html).

Least privilege needs both scopes: the IAM policy limits which workgroup and which APIs the role can call, and the database permissions of `agent_support` limit what its SQL can read.

## Workflow

![Workflow for the AWS MCP Server path. An AI assistant reaches the managed AWS MCP Server through the MCP Proxy for AWS, signed with a dedicated agent profile. The server's run script tool calls the Redshift Data API as the agent-redshift-readonly role, with the role's own permissions and no AWS MCP Server specific actions, and Redshift maps it to the database user IAMR:agent-redshift-readonly with the agent_support database role. Guardrails: a dedicated profile, deny statements applied as a service control policy or an identity policy that deny SQL on workgroups without the agent-access tag and deny infrastructure changes through agents, an IAM policy that allows only GetCredentials sign-in on one workgroup, per-user limits, and database grants, row-level security and masking.](../../images/access-path-aws-mcp-server.png)

1. Client: an AI assistant with the MCP Proxy for AWS, which signs requests with the dedicated agent profile.
2. Service: the AWS MCP Server, whose `aws___run_script` tool calls AWS APIs; the shared deny statements act here.
3. IAM role and policy: `agent-redshift-readonly` with `agent-data-plane-policy.json`; no AWS MCP Server actions are needed.
4. Sign-in and database user: `IAMR:agent-redshift-readonly`, through the Data API on workgroups tagged `agent-access=true`, with `statement_timeout` and `CONNECTION LIMIT` set on the user.
5. Database role and permissions: `agent_support`, with its grants, row-level security and masking.
6. Data: Redshift managed storage, or Apache Iceberg tables governed by Lake Formation permissions.

## Guardrails on this path

| Layer | Guardrail | Where it's set | File or setting |
| --- | --- | --- | --- |
| Agent layer | Dedicated agent profile, not your administrator profile; one profile only, so the agent can't switch to another | MCP Proxy for AWS | `--profile redshift-agent` (step 7) |
| Access layer | Deny Data API SQL on workgroups without `agent-access=true`, and deny Redshift infrastructure changes, on requests through AWS managed MCP servers | SCP or identity policy | [`deny-mcp-sql-on-untagged-workgroups.json`](../shared/deny-mcp-sql-on-untagged-workgroups.json), [`deny-infra-changes-through-agents.json`](../shared/deny-infra-changes-through-agents.json) (step 2a) |
| Access layer | Workgroup tag `agent-access=true`, set by an administrator outside any agent | Redshift Serverless | Step 2b |
| Access layer | The role's own downstream permissions, with no AWS MCP Server specific actions | IAM | [`agent-data-plane-policy.json`](../shared/agent-data-plane-policy.json) |
| Access layer | Sign-in only with `redshift-serverless:GetCredentials` (or `redshift:GetClusterCredentialsWithIAM` on a provisioned cluster), never `redshift:GetClusterCredentials` or a Secrets Manager secret, which let a caller pick another database user | IAM | `RunSqlOnOneWorkgroup` in `agent-data-plane-policy.json` |
| Data layer | Grants on one database role, row-level security, column privileges, masking | Redshift | [`agent-role.sql`](../../data-layer/agent-role.sql), [`fine-grained-access.sql`](../../data-layer/fine-grained-access.sql) |
| Cost envelope | `statement_timeout` and `CONNECTION LIMIT` on the agent's database user | Redshift | Step 6 |
| Cost envelope | Workgroup max capacity and daily usage limit | Redshift Serverless | `cost-envelope/serverless-ceilings.sh` (see Related) |

## Files

This folder has no files; set up uses the linked files below: the four files in [`../shared/`](../shared/) and [`../../data-layer/agent-role.sql`](../../data-layer/agent-role.sql), [`../../data-layer/redshiftdbroles-tag.sh`](../../data-layer/redshiftdbroles-tag.sh) (quoted lines only) and [`../../data-layer/fine-grained-access.sql`](../../data-layer/fine-grained-access.sql).

## Prerequisites

- An Amazon Redshift Serverless workgroup for agents, and the example schema `sales.orders`, `sales.customers` and `sales.payments` (see the root README).
- AWS CLI v2, `jq`, and `uv` so the MCP client can start the proxy with `uvx`.
- An IAM administrator for steps 1 and 2, an AWS Organizations administrator for the SCP form in step 2a, an administrator for the tag in step 2b, and a database administrator (superuser, or a user with `sys:secadmin` for the row-level security and masking statements) for steps 4 to 6. The SQL on this page runs in database `dev`.
- Your own AWS CLI profile (`developer` in the examples) that may assume the agent role.

Database identity on this path:

| IAM role | Database user | Database role | Where the grants come from | Row-level security and masking |
| --- | --- | --- | --- | --- |
| `agent-redshift-readonly` (profile `redshift-agent`), the same as the Redshift MCP Server path | `IAMR:agent-redshift-readonly` | `agent_support` | Step 4a creates `agent_support` and its grants from `agent-role.sql` without its last line; step 4b gives the role to the user. Skip both if you already set up the Redshift MCP Server path | Step 5: `fine-grained-access.sql` as is; its policies attach to `agent_support` |

Placeholders in this path:
- `<developer-role>`: the IAM role behind your `developer` profile, which the agent role trusts.
- `<agent-workgroup>` and `<agent-workgroup-id>`: the agent workgroup's name (for example `agents-wg`) and ID.
- `<workgroup-arn>`: the agent workgroup's ARN, for the tag.
- `<untagged-workgroup>`: a workgroup without the tag, for Verify.
- `<policy-id>` and `<sandbox-ou-id>`: the SCP's ID and the sandbox OU.
- `<id>`: the statement ID that `execute-statement` returns.
- `111122223333` and `us-east-1`: the example account ID and Region. Replace them with yours, including inside the `shared` files.

## Set up

Run each block from the repository root; each one starts with the `cd` it needs. If you already completed the Redshift MCP Server path with the same role, skip steps 1 to 6; steps 2a, 2b, 7 and 8 still apply.

### 1. Create the IAM role

```bash
cd access-layer/aws-mcp-server
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
- Writes the generated trust file `agent-redshift-readonly-trust.json` in this folder (don't commit it), checks it (`[]` means no errors) and creates the role `agent-redshift-readonly`, which only your developer role can assume.

### 2. Attach the policy

Replace `111122223333`, `us-east-1` and `<agent-workgroup-id>` in `../shared/agent-data-plane-policy.json` first, and attach it with `file://` so the shell doesn't rewrite `${aws:userid}`.

```bash
cd access-layer/aws-mcp-server
aws iam put-role-policy --role-name agent-redshift-readonly --policy-name agent-data-plane \
  --policy-document file://../shared/agent-data-plane-policy.json
aws iam get-role-policy --role-name agent-redshift-readonly --policy-name agent-data-plane
```

No AWS MCP Server specific IAM actions are needed; your role needs the same permissions as a direct Data API call.

What this does:
- Adds the inline policy `agent-data-plane`: list workgroups, sign in and run SQL on one workgroup, and read only the results of the role's own statements.

### 2a. Apply the shared deny statements

Build the policy document from the two statement files:

```bash
cd access-layer/shared
jq -s '{Version: "2012-10-17", Statement: .}' \
  deny-mcp-sql-on-untagged-workgroups.json deny-infra-changes-through-agents.json > agent-denies-policy.json
```

> [!NOTE]
> `agent-denies-policy.json` is a generated file. Don't commit it.

Then apply it in one of two forms. As a service control policy, on a sandbox OU first:

> [!WARNING]
> SCPs don't affect users or roles in the management account. Use the identity policy form for a role there.

```bash
cd access-layer/shared
aws organizations create-policy --type SERVICE_CONTROL_POLICY --name agent-denies \
  --description "Deny SQL on untagged workgroups and infrastructure changes through AWS managed MCP servers" \
  --content file://agent-denies-policy.json
aws organizations attach-policy --policy-id <policy-id> --target-id <sandbox-ou-id>
```

Or as an identity policy on the agent role:

```bash
cd access-layer/shared
aws iam put-role-policy --role-name agent-redshift-readonly --policy-name agent-denies \
  --policy-document file://agent-denies-policy.json
aws iam get-role-policy --role-name agent-redshift-readonly --policy-name agent-denies
```

What this does:
- Denies, on requests through AWS managed MCP servers, Data API SQL on workgroups without `agent-access=true` and Redshift and Redshift Serverless infrastructure changes, including tag changes. Direct CLI calls with the same profile aren't affected; the role's own policy bounds them.
- The [shared controls README](../shared/) has the same steps with their verify and cleanup.

### 2b. Tag the agent workgroup

Run this as an administrator, outside any agent (the deny statements deny tag changes made through an agent):

```bash
cd access-layer/aws-mcp-server
aws redshift-serverless tag-resource --resource-arn <workgroup-arn> --tags key=agent-access,value=true
aws redshift-serverless list-tags-for-resource --resource-arn <workgroup-arn>
```

What this does:
- Adds `agent-access=true` to the workgroup; `list-tags-for-resource` shows it. The key and the value are case-sensitive.

### 3. Create the database user

Add the `redshift-agent` profile unless it already exists, then sign in once through the Data API:

```bash
cd access-layer/aws-mcp-server
aws configure list-profiles | grep -qx redshift-agent || cat ../shared/aws-config-example.ini >> ~/.aws/config
aws redshift-data execute-statement --workgroup-name <agent-workgroup> --database dev \
  --sql "SELECT current_user" --profile redshift-agent --region us-east-1
aws redshift-data describe-statement --id <id> --profile redshift-agent --region us-east-1 --query Status
aws redshift-data get-statement-result --id <id> --profile redshift-agent --region us-east-1 \
  --query "Records[0][0].stringValue"
```

What this does:
- Adds `[profile redshift-agent]` to `~/.aws/config` (edit the account ID and `source_profile` in the file first). It skips the append when `aws configure list-profiles` already lists `redshift-agent`, for example after the Redshift MCP Server path or the shared controls README: a second block makes every AWS CLI command fail.
- Run `describe-statement` until it shows `"FINISHED"`; `get-statement-result` returns `"IAMR:agent-redshift-readonly"`. This first sign-in creates the database user, with no privileges yet.

### 4. Grant database permissions

Two parts: create the database role (4a), then give it to the agent's user (4b). Both run in database `dev`. Skip both if you already set up the Redshift MCP Server path.

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
- Variant A stores a grant of `agent_support` to the user.
- Variant B maps the IAM role to `agent_support` for each session that signs in while the tag is set; audit it with `aws iam list-role-tags --role-name agent-redshift-readonly`.

### 5. Add row-level security and masking

As a database administrator, run [`fine-grained-access.sql`](../../data-layer/fine-grained-access.sql) as is. Skip this step if you already ran the file for another path; the policies attach to `agent_support`, so every user that holds the role is already covered.

What this does:
- Filters `sales.orders` to `region = 'west'` rows with `rls_region_west`, grants four columns of `sales.customers`, and masks `sales.payments(card_number)` with `mask_card_last4`, all for `agent_support`.

### 6. Set per-user limits

As a database administrator. Skip this step if you already set the limits for the Redshift MCP Server path.

```sql
ALTER USER "IAMR:agent-redshift-readonly" SET statement_timeout TO 120000;
ALTER USER "IAMR:agent-redshift-readonly" CONNECTION LIMIT 10 SESSION TIMEOUT 300;
```

Superusers ignore connection limits.

What this does:
- Stops any statement of this user after 120 seconds, allows at most 10 concurrent connections, and ends sessions idle for 300 seconds.

### 7. Configure the MCP Proxy for AWS

Add the proxy to your MCP client's configuration, for example `~/.kiro/settings/mcp.json` in Kiro:

```json
{
  "mcpServers": {
    "aws-mcp": {
      "command": "uvx",
      "args": ["mcp-proxy-for-aws-cli@1.7.0", "https://aws-mcp.us-east-1.api.aws/mcp",
               "--profile", "redshift-agent", "--metadata", "AWS_REGION=us-east-1"]
    }
  }
}
```

What this does:
- Runs the version-pinned `mcp-proxy-for-aws-cli` distribution of the MCP Proxy for AWS, which signs every request with the `redshift-agent` profile. Check [PyPI](https://pypi.org/project/mcp-proxy-for-aws-cli/) for newer versions.
- `--metadata AWS_REGION=us-east-1` sets the default Region for the server's AWS API calls. Use the endpoint and Region you work in; [Setting up the AWS MCP Server](https://docs.aws.amazon.com/aws-mcp/latest/userguide/getting-started-aws-mcp-server.html) lists the endpoints.
- Passes one profile only. With more than one, the proxy lets the agent pick a profile on each call ([Multi-profile support](https://docs.aws.amazon.com/agent-toolkit/latest/userguide/multi-account-access.html)).

### 8. Try it

Restart the MCP client and ask the assistant to run `SELECT current_user` on `<agent-workgroup>` with the Redshift Data API. The answer is `IAMR:agent-redshift-readonly`.

## Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| `SELECT current_user` on the tagged agent workgroup, through the assistant | agent role, through the MCP Proxy for AWS | statement `FINISHED`, result `IAMR:agent-redshift-readonly` |
| `SELECT current_user` on `<untagged-workgroup>`, through the assistant | agent role, through the MCP Proxy for AWS | `AccessDeniedException ... with an explicit deny in a service control policy` (SCP form) or `... with an explicit deny in an identity-based policy` (identity policy form) |
| Ask the assistant to tag a workgroup | agent role, through the MCP Proxy for AWS | explicit deny on `redshift-serverless:TagResource` |
| The same SQL run directly with `aws redshift-data execute-statement --profile redshift-agent` | agent role, direct CLI call | bounded by the role's own policy only: it works on the workgroup in `RunSqlOnOneWorkgroup` and gets AccessDenied elsewhere; the deny statements match only requests through AWS managed MCP servers |
| `SELECT usename, useconnlimit FROM pg_user_info WHERE usename = 'IAMR:agent-redshift-readonly';` | database administrator | `useconnlimit` is `10` |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| Explicit deny on the agent workgroup | The tag is missing or misspelled; the key and value are case-sensitive `agent-access` = `true` | Tag the workgroup again (step 2b), as an administrator outside the agent |
| No deny in the management account | SCPs don't affect users or roles in the management account | Use the identity policy form in step 2a |
| The proxy uses the wrong identity | `AWS_MCP_PROXY_PROFILES` in the environment takes precedence over `--profile`, or the client configuration names another profile | Remove `AWS_MCP_PROXY_PROFILES` or set it to `redshift-agent`; `aws sts get-caller-identity --profile redshift-agent` shows the agent role |
| AccessDenied on a `redshift-data:` or `redshift-serverless:` action through the server, while the same call works directly with the CLI under another profile | The proxy signs with a different profile than the direct call; the server adds no permissions of its own | Give the role the same permissions as a direct call (step 2) and check the profile in step 7 |
| `rls policy "rls_region_west" already exists` in step 5 | The file already ran for another path | Nothing to change: the policies attach to `agent_support` |
| `permission denied for schema sales` after tagging in step 4b, variant B | `agent_support` doesn't exist because step 4a was skipped, or the agent hasn't signed in again since the tag change | Run step 4a, then sign in again |
| `AccessDenied` calling `AssumeRole` with the `redshift-agent` profile | The trust policy's principal isn't your developer role's full ARN. For IAM Identity Center roles that ARN includes the `aws-reserved/sso.amazonaws.com/` path, followed by the Region of your IAM Identity Center instance unless it's `us-east-1`, as in `arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/eu-west-2/AWSReservedSSO_<permission-set>_<suffix>` | `aws sts get-caller-identity --profile developer` shows the role name in its assumed-role session ARN, which has no path. `aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ --query "Roles[].Arn"` shows the full role ARN to put in the trust policy |
| Every AWS CLI command fails with `Unable to parse config file` | `~/.aws/config` has two `[profile redshift-agent]` blocks, because the profile was appended twice | Delete one of the two blocks |

## Clean up

1. Remove the `aws-mcp` entry from the MCP client configuration.
2. If no path still uses the workgroup as an agent workgroup, remove the tag:

   ```bash
   aws redshift-serverless untag-resource --resource-arn <workgroup-arn> --tag-keys agent-access
   ```

3. Leave the `agent-denies` SCP in place. The [shared controls Clean up](../shared/README.md#clean-up) detaches and deletes it, and the root README's clean-up order runs it last, after every path, so agents stay bounded until they're gone. Unless the Redshift MCP Server path still uses the role and user, continue with steps 4 to 6.
4. As a database administrator in `dev` (skip the `REVOKE` if you used the `RedshiftDbRoles` tag):

   ```sql
   REVOKE ROLE agent_support FROM "IAMR:agent-redshift-readonly";
   DROP USER "IAMR:agent-redshift-readonly";
   ```

5. Delete the IAM role. Its inline policies may be `agent-data-plane`, plus `agent-denies` for the identity policy form, plus `redshiftdbroles-tag-read` if you used the tag; `delete-role` fails with `DeleteConflict` while any remains.

   ```bash
   aws iam list-role-policies --role-name agent-redshift-readonly
   aws iam delete-role-policy --role-name agent-redshift-readonly --policy-name agent-data-plane
   aws iam delete-role-policy --role-name agent-redshift-readonly --policy-name agent-denies
   aws iam delete-role-policy --role-name agent-redshift-readonly --policy-name redshiftdbroles-tag-read
   aws iam list-attached-role-policies --role-name agent-redshift-readonly
   aws iam delete-role --role-name agent-redshift-readonly
   ```

   Run `delete-role-policy` once for each name that `list-role-policies` returns; `list-attached-role-policies` is expected to return an empty list.
6. Remove the `[profile redshift-agent]` block from `~/.aws/config`, and delete the generated files:

   ```bash
   cd access-layer/aws-mcp-server
   rm -f agent-redshift-readonly-trust.json ../shared/agent-denies-policy.json
   ```

7. Then run the data-layer cleanup if no other path still uses `agent_support` or row-level security on `sales.orders`.

## Related

- [Shared controls](../shared/): the deny statements, the data plane policy and the profile, with their own verify and cleanup.
- [Data layer](../../data-layer/): database identity and roles, the `RedshiftDbRoles` tag, rows, columns and values, and their cleanup.
- More limits: [cost-envelope](../../cost-envelope/)
- [Observe: attribution](../../observe/attribution/): which client and role ran each query, including the CloudTrail records of AWS MCP Server tool calls.
- The other paths: [Redshift MCP Server](../redshift-mcp-server/), [custom MCP server](../custom-mcp-server/), [AgentCore custom agent](../agentcore-custom-agent/), [Bedrock Knowledge Bases](../bedrock-knowledge-base/).
