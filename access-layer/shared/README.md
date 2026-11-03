# Shared controls: one allow list, two deny statements and an agent profile

These files are the access controls that more than one access path uses: the IAM allow list on every agent role that runs SQL through the Data API, two deny statements you apply once for every agent identity, and the AWS CLI profile that keeps an AI assistant on the agent role. Each path README links here for the shared parts and repeats the commands it needs, so you can also set them up from your path's README.
In the accompanying blog post: sections "Data plane: a narrow tool surface on every path" and "Control plane: keep infrastructure changes out of agents' reach".

## When to use it

Every agent deployment. These controls address excessive agency: an agent that can call infrastructure APIs, or run SQL on a workgroup that isn't meant for agents, can do more than its task needs. The data plane policy is normally attached to each agent role when the role is created. The deny statements are normally applied once, by an organization or account administrator, as a service control policy on the organizational unit that holds the agent accounts, or as an identity policy on each agent role. The profile is used on developers' machines where AI assistants run.

## Who runs it

- An AWS Organizations administrator, for the service control policy (SCP) form of the deny statements.
- An IAM administrator, for the identity policy form, for attaching the data plane policy and for the agent roles.
- A Redshift administrator, for the `agent-access=true` workgroup tag. Tag workgroups outside any agent: the deny statements also deny tag changes made through AWS managed MCP servers.
- Each developer, for the profile in their own `~/.aws/config`.

## Prerequisites

- An agent IAM role. Each path README creates one in its step 1: [Redshift MCP Server](../redshift-mcp-server/), [AWS MCP Server](../aws-mcp-server/), [custom MCP server](../custom-mcp-server/), [AgentCore custom agent](../agentcore-custom-agent/).
- For the SCP form: AWS Organizations, with a sandbox organizational unit (OU) to try the policy on first. See [Service control policies (SCPs)](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html) in the AWS Organizations User Guide.
- `jq`, to wrap the two deny statements into a policy document.
- For the profile: your own AWS CLI profile (`developer` in the example) that the agent role's trust policy lets assume the role.

Placeholders:
- `<agent-role-name>`: the agent's IAM role, for example `agent-redshift-readonly`.
- `<agent-workgroup-id>` in `agent-data-plane-policy.json`: the ID of the one workgroup the agent may run SQL on.
- `<policy-id>`: the ID that `aws organizations create-policy` returns, for example `p-examplepolicyid`.
- `<sandbox-ou-id>`: the OU you attach the SCP to first.
- `<workgroup-arn>`: the ARN of an agent workgroup.
- `111122223333` and `us-east-1`: the example account ID and Region in the JSON and INI files. Replace them with yours.
- `developer`: your own AWS CLI profile, named in `source_profile`.
- `redshift-agent` and `agent-redshift-readonly`: the example agent profile and role.

## How it works

`agent-data-plane-policy.json` is the allow list on every agent role: it allows SQL on one workgroup and reading only the results of the role's own statements. The two deny statements take effect only on requests made through AWS managed MCP servers, because they use the `aws:ViaAWSMCPService` condition key, which AWS MCP Server sets to `true` on every request it forwards ([How AWS MCP Server works with IAM](https://docs.aws.amazon.com/aws-mcp/latest/userguide/security_iam_service-with-iam.html)); they're a backstop for the AWS MCP Server path, applied once so that any agent identity that later uses an AWS managed MCP server is covered. The profile keeps an AI assistant, and the MCP servers it starts, on the agent role instead of the developer's own role.

For a picture of where these controls sit on each path, see [Guardrails on each path](../README.md#guardrails-on-each-path).

## Files

| File | What it is | Where you use it | Identity | Used by paths |
| --- | --- | --- | --- | --- |
| [`agent-data-plane-policy.json`](agent-data-plane-policy.json) | IAM policy with three statements. `Discover` allows `redshift-serverless:ListWorkgroups` and `GetWorkgroup` on `*`, because `ListWorkgroups` doesn't support resource-level permissions. `RunSqlOnOneWorkgroup` allows `redshift-serverless:GetCredentials`, `redshift-data:ExecuteStatement` and `redshift-data:BatchExecuteStatement` on one workgroup; this is the statement that limits where SQL runs. `ReadOwnStatements` allows `DescribeStatement` and `GetStatementResult` only when `redshift-data:statement-owner-iam-userid` equals `${aws:userid}` | Inline policy `agent-data-plane` on each agent role (Set up step 1) | attached to the agent IAM role | Redshift MCP Server, AWS MCP Server, custom MCP server, AgentCore custom agent; also act-refund and observe |
| [`deny-mcp-sql-on-untagged-workgroups.json`](deny-mcp-sql-on-untagged-workgroups.json) | One IAM statement, not a full policy document. It denies `ExecuteStatement` and `BatchExecuteStatement` through AWS managed MCP servers on any workgroup without the tag `agent-access=true`. Wrap it with the `jq` command in step 2 before you attach it | SCP on an OU (step 3) or identity policy on each agent role (step 4) | applies to every agent identity in the OU, or attached to the agent IAM role | AWS MCP Server (applied for every agent identity) |
| [`deny-infra-changes-through-agents.json`](deny-infra-changes-through-agents.json) | One IAM statement. It denies Redshift and Redshift Serverless create, delete, modify, resize, pause, resume, reboot, restore and tagging actions made through AWS managed MCP servers. Same wrapper and the same two forms | SCP or identity policy, with the statement above | applies to every agent identity in the OU, or attached to the agent IAM role | AWS MCP Server (applied for every agent identity) |
| [`aws-config-example.ini`](aws-config-example.ini) | The `redshift-agent` profile for `~/.aws/config`. It assumes the agent role from your `developer` profile; role chaining caps each session at 1 hour, and the AWS CLI and SDKs refresh it | `~/.aws/config` on the developer's machine (step 6) | assumes `agent-redshift-readonly` from your `developer` profile | Redshift MCP Server, AWS MCP Server; also observe |

## Set up

Run each block from the repository root; each one starts with the `cd` it needs. Replace the placeholders first, including `111122223333`, `us-east-1` and `<agent-workgroup-id>` inside `agent-data-plane-policy.json` and the account ID in `aws-config-example.ini`.

### 1. Attach the data plane policy to an agent role

> [!WARNING]
> Attach the policy with `file://`. Pasting the JSON into a shell can rewrite `${aws:userid}`, and the `ReadOwnStatements` statement then matches no statement. Check the stored policy with `get-role-policy`.

```bash
cd access-layer/shared
aws iam put-role-policy --role-name <agent-role-name> --policy-name agent-data-plane \
  --policy-document file://agent-data-plane-policy.json
aws iam get-role-policy --role-name <agent-role-name> --policy-name agent-data-plane
```

What this does:
- Adds the inline policy `agent-data-plane` to the role.
- `get-role-policy` shows the stored document; the condition value must read `${aws:userid}`.

> [!NOTE]
> The policy is written for Amazon Redshift Serverless. For a provisioned cluster, replace `redshift-serverless:GetCredentials` with `redshift:GetClusterCredentialsWithIAM` on the cluster's `dbname` resource, and add `redshift:DescribeClusters` to `Discover`. Don't add `redshift:GetClusterCredentials`: it lets the caller choose another database user.

### 2. Build the deny policy document

Each deny file is one statement, so wrap both into one policy document:

```bash
cd access-layer/shared
jq -s '{Version: "2012-10-17", Statement: .}' \
  deny-mcp-sql-on-untagged-workgroups.json deny-infra-changes-through-agents.json > agent-denies-policy.json
```

What this does:
- Writes `agent-denies-policy.json` with a `Version` and a two-statement `Statement` array. Steps 3 and 4 attach this file.

> [!NOTE]
> `agent-denies-policy.json` is a generated file. Don't commit it; build it again from the two statement files when you need it.

### 3. Apply it as a service control policy

> [!WARNING]
> SCPs don't affect users or roles in the management account. Attach the policy to a sandbox OU first, check the Verify rows there, then attach it to the OUs that hold your agent accounts.

```bash
cd access-layer/shared
aws organizations create-policy --type SERVICE_CONTROL_POLICY --name agent-denies \
  --description "Deny SQL on untagged workgroups and infrastructure changes through AWS managed MCP servers" \
  --content file://agent-denies-policy.json
aws organizations attach-policy --policy-id <policy-id> --target-id <sandbox-ou-id>
```

What this does:
- Creates the SCP `agent-denies`; `create-policy` returns its ID in `Policy.PolicySummary.Id`.
- Attaches it to the sandbox OU. Every IAM identity in the OU's member accounts is then denied the two statements' actions when they arrive through an AWS managed MCP server.

### 4. Or apply it as an identity policy on each agent role

Use this form instead of step 3 when you don't use AWS Organizations, or for an agent role in the management account.

```bash
cd access-layer/shared
aws iam put-role-policy --role-name <agent-role-name> --policy-name agent-denies \
  --policy-document file://agent-denies-policy.json
aws iam get-role-policy --role-name <agent-role-name> --policy-name agent-denies
```

What this does:
- Adds the inline policy `agent-denies` to the role; `get-role-policy` shows both statements.

Don't use these statements as a permissions boundary. A boundary sets the maximum permissions, so a boundary with only Deny statements leaves the role with none.

### 5. Tag each agent workgroup

Run this as an administrator, outside any agent:

```bash
cd access-layer/shared
aws redshift-serverless tag-resource --resource-arn <workgroup-arn> --tags key=agent-access,value=true
aws redshift-serverless list-tags-for-resource --resource-arn <workgroup-arn>
```

What this does:
- Adds the tag `agent-access=true` to the workgroup. The SQL deny statement allows agents through AWS managed MCP servers only on workgroups with this tag. The key and the value are case-sensitive.

### 6. Add the agent profile

Edit the account ID in `role_arn` and the `source_profile` name in `aws-config-example.ini`, then append it to your AWS CLI configuration unless a profile named `redshift-agent` already exists:

```bash
cd access-layer/shared
aws configure list-profiles | grep -qx redshift-agent || cat aws-config-example.ini >> ~/.aws/config
```

What this does:
- Adds the profile `redshift-agent`, which assumes `agent-redshift-readonly` from your `developer` profile. Set `AWS_PROFILE=redshift-agent` where the AI assistant starts and in each MCP server's configuration.
- Skips the append when `aws configure list-profiles` already lists `redshift-agent`, for example because a path README added it. A second `[profile redshift-agent]` block makes every AWS CLI command fail, for every profile.

## Verify

Run the policy checks from the `shared` folder:

```bash
cd access-layer/shared
aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY \
  --policy-document file://agent-denies-policy.json --query "findings[?findingType=='ERROR']"
aws accessanalyzer validate-policy --policy-type SERVICE_CONTROL_POLICY \
  --policy-document file://agent-denies-policy.json --query "findings[?findingType=='ERROR']"
aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY \
  --policy-document file://agent-data-plane-policy.json --query "findings[?findingType=='ERROR']"
aws sts get-caller-identity --profile redshift-agent
```

Pass `agent-denies-policy.json` to `validate-policy`, never the two statement files on their own.

| Check | Run as | Expected result |
| --- | --- | --- |
| `validate-policy` on `agent-denies-policy.json` with `IDENTITY_POLICY` and with `SERVICE_CONTROL_POLICY` | IAM administrator | `[]`: no findings of type `ERROR` |
| `validate-policy` on `agent-data-plane-policy.json` with `IDENTITY_POLICY` | IAM administrator | `[]`: no findings of type `ERROR` |
| Through the AWS MCP Server, Data API SQL on a workgroup without the `agent-access=true` tag | agent role, through the MCP Proxy for AWS | `AccessDeniedException ... with an explicit deny in a service control policy` for the SCP form, or `... with an explicit deny in an identity-based policy` for the identity policy form |
| Through the AWS MCP Server, `redshift-serverless:TagResource` on any workgroup | agent role, through the MCP Proxy for AWS | `AccessDeniedException` with an explicit deny |
| `aws sts get-caller-identity --profile redshift-agent` | developer | `arn:aws:sts::111122223333:assumed-role/agent-redshift-readonly/...` |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| The SCP has no effect | The account is the organization's management account, which SCPs don't affect | Use the identity policy form (step 4) for roles in the management account, or run agents in a member account |
| `${aws:userid}` became empty in the stored policy, and `DescribeStatement` or `GetStatementResult` returns AccessDenied | The JSON was pasted into a shell, which rewrote `$` | Attach the file again with `file://` (step 1), then check it with `aws iam get-role-policy` |
| `not authorized to perform: redshift-data:DescribeStatement because no identity-based policy allows` it, for a statement the same profile just ran | `ReadOwnStatements` matches the statement's owner by `${aws:userid}`, which for a role includes the role session name. The AWS CLI started a new role session between the two calls: it renews cached role credentials shortly before they expire, and a chained role session lasts at most one hour | Run the statement again and read its result in the same role session, or right after it |
| `MalformedPolicyDocument` from `put-role-policy`, or `ERROR` findings from `validate-policy` | A bare deny file was passed instead of the wrapped `agent-denies-policy.json`; each file is one statement, not a policy document | Run the `jq` wrapper in step 2 and pass `agent-denies-policy.json` |
| `aws redshift-data list-statements` fails with AccessDenied | `ListStatements` has no statement owner, so the `ReadOwnStatements` statement doesn't cover it | Attach the `ListOwnStatements` statement as a second inline policy with the `put-role-policy --policy-name list-own-statements` command in [step 2 of the custom MCP server README](../custom-mcp-server/README.md#2-attach-the-policy), with your role name in `--role-name` |
| The `redshift-agent` profile session expires after an hour | Role chaining caps the session at 1 hour | Nothing to fix: the AWS CLI and SDKs refresh the session from the `developer` profile |
| Every AWS CLI command fails with `Unable to parse config file` | `~/.aws/config` has two `[profile redshift-agent]` blocks, because the profile was appended twice | Delete one of the two blocks |

## Clean up

The root README's clean-up order runs this last. By then the path cleanups have deleted the roles they created, with their inline policies, so remove only what's left:

```bash
cd access-layer/shared
# SCP form: detach from every target, then delete
aws organizations detach-policy --policy-id <policy-id> --target-id <sandbox-ou-id>
aws organizations delete-policy --policy-id <policy-id>
# Identity policy form: for each agent role you keep
aws iam delete-role-policy --role-name <agent-role-name> --policy-name agent-denies
# Only if the role no longer runs SQL
aws iam delete-role-policy --role-name <agent-role-name> --policy-name agent-data-plane
# For a workgroup that is no longer an agent workgroup
aws redshift-serverless untag-resource --resource-arn <workgroup-arn> --tag-keys agent-access
# The generated policy document, if a path cleanup didn't remove it
rm -f agent-denies-policy.json
```

Then remove the `[profile redshift-agent]` block from `~/.aws/config` if a path cleanup didn't.

## Used by

- [Redshift MCP Server](../redshift-mcp-server/): the data plane policy and the `redshift-agent` profile.
- [AWS MCP Server](../aws-mcp-server/): all four files; the deny statements act on this path.
- [Custom MCP server](../custom-mcp-server/): the data plane policy.
- [AgentCore custom agent](../agentcore-custom-agent/): the data plane policy.
- [Bedrock Knowledge Bases](../bedrock-knowledge-base/): none of these files. The knowledge base service role uses its own `kb-service-role-policy.json`, and the deny statements don't act on Knowledge Bases requests.
- [act-refund](../../act-refund/): the data plane policy on the action identity and the procedure owner.
- [observe/health-checks-and-retention](../../observe/health-checks-and-retention/): the data plane policy and the profile for the scheduled review.
