# Access layer: limit what the agent can call

The access layer decides which tools an agent can call and what each call can do: which AWS APIs, which workgroup, and which database user it signs in as. It addresses excessive agency, so a prompt can't widen what the agent is allowed to reach.
In the accompanying blog post: section "Access layer: limit what the agent can call".

Pick the folder that matches how your agent reaches Amazon Redshift. Each path README is self-contained: it lists the IAM role, the IAM policy, the database user, the database role and permissions, and the client configuration for that path, with setup, verify, common errors and clean up steps.

## Choose your path

| If your agent ... | Start here | Where it's normally used | Identity Redshift sees | Then |
| --- | --- | --- | --- | --- |
| is an AI assistant such as Kiro with the Amazon Redshift MCP Server | [`redshift-mcp-server/`](redshift-mcp-server/) | Developers' self-service in AI assistants such as Kiro, with the open-source server running on their own machine | `IAMR:agent-redshift-readonly`, from a dedicated `redshift-agent` profile | [`data-layer/`](../data-layer/), [`cost-envelope/`](../cost-envelope/), [`observe/`](../observe/) |
| is an AI assistant that reaches AWS through the AWS MCP Server | [`aws-mcp-server/`](aws-mcp-server/) | Developers and analysts working through the managed AWS MCP Server and the MCP Proxy for AWS | `IAMR:agent-redshift-readonly`, the same role and profile as the Redshift MCP Server path | [`data-layer/`](../data-layer/), [`cost-envelope/`](../cost-envelope/), [`observe/`](../observe/) |
| is an application or agent with an MCP server you write | [`custom-mcp-server/`](custom-mcp-server/) | Production applications with a fixed tool set, where the agent chooses only parameters | `IAMR:agent-sales-metrics`, the server's own role | [`data-layer/`](../data-layer/), [`cost-envelope/`](../cost-envelope/), [`observe/`](../observe/) |
| is a custom agent on Amazon Bedrock AgentCore (a Runtime tool, or a Lambda tool behind AgentCore Gateway) | [`agentcore-custom-agent/`](agentcore-custom-agent/) | Custom agents in production on AgentCore | `IAMR:agent-support`, the runtime execution role or the Lambda function role | [`data-layer/`](../data-layer/), [`cost-envelope/`](../cost-envelope/), [`observe/`](../observe/) |
| serves end users asking questions through Amazon Bedrock Knowledge Bases | [`bedrock-knowledge-base/`](bedrock-knowledge-base/) | Managed natural-language query for end users | `IAMR:<kb-role>`, the knowledge base service role, for every end user | [`data-layer/`](../data-layer/), [`cost-envelope/`](../cost-envelope/), [`observe/`](../observe/) |

Without a dedicated identity, an AI assistant and the MCP servers it starts run as the developer's own AWS profile, so Redshift sees a user such as `IAMR:DataPlatformAdmin` with that role's grants. Every path above gives the agent its own IAM role, so it gets its own policies, cost and audit trail.

## Who Redshift sees on each path

![Three access paths and the identity Amazon Redshift sees on each. A self-service AI assistant with the Redshift MCP Server or AWS MCP Server acts with the user's AWS profile, so its queries run as a database user such as IAMR:DataPlatformAdmin. A custom agent in AgentCore Runtime, or a Lambda tool behind AgentCore Gateway, uses its execution role, such as IAMR:agent-support. Bedrock Knowledge Bases uses one identity for all its end users: its service role, a database user on provisioned clusters, or a Secrets Manager user, so row-level security can't tell those users apart. Every path needs an IAM policy and database permissions. A band says one identity per agent gives it its own policies, cost, and audit.](../images/fig2-identity-map.png)

Redshift maps an IAM role that signs in with IAM credentials to a database user named `IAMR:<role name>`. That database user's grants, row-level security and masking decide what the agent's SQL can read, whatever the agent was asked to do.

## Guardrails on each path

![Four access paths, each with what the agent can send, its guardrail, and how it connects. Redshift MCP Server: any SQL; read-only mode: nothing a query changes is kept; one Data API call per tool call. AWS MCP Server: Python in aws___run_script; an agent profile and IAM policies on aws:ViaAWSMCPService; one Data API call per statement. Custom MCP server: only tool parameters; fixed SQL and validated parameters, with AgentCore Policy checking each call at AgentCore Gateway. Bedrock Knowledge Bases: questions turned into SQL; one database and up to 50 tables, with descriptions and example queries steering the SQL; one session per Retrieve call. A band adds CONNECTION LIMIT and statement_timeout on every path, and SESSION TIMEOUT for idle driver sessions.](../images/fig3-access-paths.png)

Each path README has a "Guardrails on this path" table that names every control, the layer it belongs to, and the file or setting that sets it.

## Shared controls

[`shared/`](shared/) holds the files that more than one path uses. Its README has the setup, verify and clean up steps for each:

- [`agent-data-plane-policy.json`](shared/agent-data-plane-policy.json): the allow list on every agent role that runs SQL through the Data API. It lets the agent list workgroups, sign in and run SQL on one workgroup, and read only the results of its own statements.
- [`deny-mcp-sql-on-untagged-workgroups.json`](shared/deny-mcp-sql-on-untagged-workgroups.json) and [`deny-infra-changes-through-agents.json`](shared/deny-infra-changes-through-agents.json): two deny statements, applied once as a service control policy or an identity policy on every agent role. They deny Data API SQL on workgroups without the `agent-access=true` tag, and Redshift infrastructure changes.
- [`aws-config-example.ini`](shared/aws-config-example.ini): the `redshift-agent` AWS CLI profile, so an AI assistant runs as the agent role instead of the developer's own.

Scope of the two deny statements: both use the `aws:ViaAWSMCPService` condition key. AWS MCP Server sets that key to `true` on every request it forwards to a downstream service, so the denies match only requests made through AWS managed MCP servers, which is the [AWS MCP Server path](aws-mcp-server/). On the other paths, the role's own allow list (`agent-data-plane-policy.json`, or `kb-service-role-policy.json` for the knowledge base) limits the workgroup and the APIs. Source: [How AWS MCP Server works with IAM](https://docs.aws.amazon.com/aws-mcp/latest/userguide/security_iam_service-with-iam.html).

## Both scopes

Least privilege on every path needs two scopes:

- The IAM policy limits which workgroups the agent can sign in to and which APIs it can call.
- The database permissions limit what its SQL can read or change: the grants on its database role, row-level security, column privileges and masking. [`data-layer/`](../data-layer/) sets them up.

Neither scope replaces the other. An IAM policy scoped to one workgroup still lets the agent read every table its database user can read, and narrow grants don't stop an agent from calling another workgroup or another AWS API.

> [!IMPORTANT]
> Agents with shell access can bypass any MCP server with the AWS CLI, so scope IAM on every path. The MCP server's own settings, such as read-only mode, apply only to calls that go through that server; the IAM policy and the database permissions apply to every call the agent's credentials make. To allow only the AWS MCP Server path, attach [`deny-data-api-outside-aws-mcp.json`](aws-mcp-server/deny-data-api-outside-aws-mcp.json) to the agent role (step 2c of [`aws-mcp-server/`](aws-mcp-server/)). IAM can't tell the local Redshift MCP Server from the AWS CLI, so on that path read-only database grants are the boundary.
