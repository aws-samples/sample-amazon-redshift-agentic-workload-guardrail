# Guardrails and cost control for agentic workloads on Amazon Redshift

This repository holds the IAM policies, SQL, AWS CLI commands and Python files that accompany the AWS Big Data Blog post on guardrails and cost control for agentic workloads with Amazon Redshift. Each folder is self-contained: its README says when to use it, who runs it, and how to set it up, verify it and clean it up.

> [!IMPORTANT]
> This is sample code, for non-production usage. You should work with your security and legal teams to meet your organizational security, regulatory and compliance requirements before deployment.

## The layered guardrail model

![The layered guardrail model for agentic analytics on Amazon Redshift, read top to bottom in four numbered rows. 1, agentic patterns: conversational analytics through AI assistants with MCP servers or apps with Knowledge Bases, Enrich with Redshift ML, Act with scoped tools behind AgentCore Gateway, and Operate with Kiro and Redshift skills. 2, the agent layer, mostly probabilistic, screens prompts and tickets, guides reasoning, and checks the answer. 3, the access layer, deterministic, keeps SQL tools read-only, blocks infrastructure changes, and scopes writes. 4, the data layer, prompt-independent, applies per-agent identity, row, column, and masking policies, output limits, and compute limits. Below, the cost envelope adds model tokens, query compute, and data at rest, with no new meter.](images/fig1-layered-model.png)

1. Agent layer: skills, tool allow lists, and approval for consequential or above-threshold writes. It lives in the agent or AI assistant, outside this repository.
2. Access layer: which tools and APIs the agent can call, and as which identity. [`access-layer/`](access-layer/README.md)
3. Data layer: what the agent's database user can read, see and copy. [`data-layer/`](data-layer/README.md)
4. Act pattern: one scoped write tool, with a person approving writes above a threshold. [`act-refund/`](act-refund/README.md)
5. Cost envelope: limits on compute and model spend. [`cost-envelope/`](cost-envelope/README.md)
6. Observe and prove: attribution, detection, cost ledger, export audit and health checks. [`observe/`](observe/README.md)

Least privilege needs both scopes on every path: an IAM policy that limits which workgroups and APIs the agent can call, and database permissions that limit what its SQL can read or change.

## Find your path

### By how your agent reaches Redshift

| If your agent ... | Start here | Then |
| --- | --- | --- |
| is an AI assistant such as Kiro with the Amazon Redshift MCP Server | [`access-layer/redshift-mcp-server/`](access-layer/redshift-mcp-server/README.md) | [`data-layer/`](data-layer/README.md), [`cost-envelope/`](cost-envelope/README.md), [`observe/`](observe/README.md) |
| is an AI assistant that reaches AWS through the AWS MCP Server | [`access-layer/aws-mcp-server/`](access-layer/aws-mcp-server/README.md) | [`data-layer/`](data-layer/README.md), [`cost-envelope/`](cost-envelope/README.md), [`observe/`](observe/README.md) |
| is an application or agent with an MCP server you write | [`access-layer/custom-mcp-server/`](access-layer/custom-mcp-server/README.md) | [`data-layer/`](data-layer/README.md), [`cost-envelope/`](cost-envelope/README.md), [`observe/`](observe/README.md) |
| is a custom agent on Amazon Bedrock AgentCore (a Runtime tool, or a Lambda tool behind AgentCore Gateway) | [`access-layer/agentcore-custom-agent/`](access-layer/agentcore-custom-agent/README.md) | [`data-layer/`](data-layer/README.md), [`cost-envelope/`](cost-envelope/README.md), [`observe/`](observe/README.md) |
| serves end users asking questions through Amazon Bedrock Knowledge Bases | [`access-layer/bedrock-knowledge-base/`](access-layer/bedrock-knowledge-base/README.md) | [`data-layer/`](data-layer/README.md), [`cost-envelope/`](cost-envelope/README.md), [`observe/`](observe/README.md) |

### By concern

| I need to ... | Go to |
| --- | --- |
| restrict what data agents see | [`data-layer/`](data-layer/README.md) |
| stop agents from changing infrastructure or querying non-agent workgroups | [`access-layer/shared/`](access-layer/shared/README.md) |
| let an agent write, with approval above a threshold | [`act-refund/`](act-refund/README.md) |
| cap spend | [`cost-envelope/`](cost-envelope/README.md) |
| cap model spend per agent | [`cost-envelope/bedrock-budget-action/`](cost-envelope/bedrock-budget-action/README.md) |
| audit agents | [`observe/`](observe/README.md) |
| find unregistered (shadow) agents | [`observe/detection/`](observe/detection/README.md) |
| check readiness before production | [`checklist/`](checklist/README.md) |

## Quick start

```bash
git clone https://github.com/aws-samples/sample-amazon-redshift-agentic-workload-guardrail.git
cd sample-amazon-redshift-agentic-workload-guardrail
```

Commands in each README assume you start in the repository root; each block begins with the `cd` it needs.

> [!WARNING]
> Start in a non-production account or workgroup. Several steps change settings for the whole workgroup (for example metadata security and the `ASSUMEROLE` revoke) or the whole organization (the service control policy). Service control policies don't apply to the management account, so run agents in a member account.

Recommended order:

1. Pick your access path in [Find your path](#find-your-path) and create its identity.
2. Set up the [data layer](data-layer/README.md) for that identity's database role.
3. Set up the [cost envelope](cost-envelope/README.md).
4. Set up [observe](observe/README.md).
5. Work through [`checklist/before-production.md`](checklist/before-production.md).

## Prerequisites

- An Amazon Redshift Serverless workgroup. The samples are written for Redshift Serverless: the `RedshiftDbRoles` tag, `redshift-serverless:GetCredentials`, usage limits and SYS_SERVERLESS_USAGE are Serverless features. For a provisioned cluster, the README of each folder names the change where one is needed, for example `redshift:GetClusterCredentialsWithIAM` and `redshift:DescribeClusters` in the data plane policy.
- AWS CLI v2, `jq`, and Python 3.10 or later with `uv`.
- Amazon Athena, for the files marked Athena.
- A database administrator (superuser, or `sys:secadmin` for the row-level security and masking statements) for the SQL.
- AWS Organizations, for the service control policy form of the shared deny statements (optional).
- The example schema below. No script in this repository creates it; create the tables with your own data, or change the names in the files.

| Table or view | Columns the files read | Used by |
| --- | --- | --- |
| `sales.orders` | `order_id`, `region`, `order_date`, `total_amount` | `data-layer/agent-role.sql`, `data-layer/fine-grained-access.sql`, `act-refund/refund_procedures.sql`, `cost-envelope/storage-compression.sql`, the custom MCP server view, the knowledge base |
| `sales.customers` | `customer_id`, `segment`, `region`, `signup_date`, and PII columns such as `email` that the agent must not read | `data-layer/fine-grained-access.sql`, `access-layer/bedrock-knowledge-base/kb-redshift-config.json` |
| `sales.payments` | `card_number VARCHAR(16)` | `data-layer/agent-role.sql`, `data-layer/fine-grained-access.sql` |
| `support.tickets` | `ticket_id`, `ticket_text`, `created_at` | `cost-envelope/model-spend-summarizer.sql`, `cost-envelope/precompute-prompts.sql` |
| `sales.v_daily_revenue` | a view of `region`, `order_date` and `total_amount` from `sales.orders` | `access-layer/custom-mcp-server/sales_metrics_mcp.py`; the [custom MCP server README](access-layer/custom-mcp-server/README.md) creates it |

`act-refund/refund_procedures.sql` creates `support.refunds` itself. The verify steps in [act-refund](act-refund/README.md) use the order IDs 1001, 1002 (with a total of 80.50) and 1007.

## Placeholders and example names

Replace every placeholder in angle brackets, and every example name you don't want to keep, after you copy a command. Each folder README lists the placeholders and example names its files use.

| Placeholder | Meaning | Appears in |
| --- | --- | --- |
| `111122223333` | The example AWS account ID | ARNs in policies, profiles and commands throughout |
| `us-east-1` in ARNs and commands | The example Region | Policies, profiles and commands; AWS Budgets is always called with `--region us-east-1` |
| `<account-id>` | Your AWS account ID | `cost-envelope/bedrock-budget-action/`, `observe/export-audit/cloudtrail-s3-writes.sql` |
| `<region>` | The Region of your agent workgroup | `cost-envelope/usage-limit-alarm.sh`, `observe/` |
| `<agent-workgroup-id>` | The ID of the one workgroup the agent may run SQL on | `access-layer/shared/agent-data-plane-policy.json` |
| `<workgroup-id>` | The workgroup ID in workgroup and usage limit ARNs | `cost-envelope/serverless-ceilings.sh`, `access-layer/bedrock-knowledge-base/` |
| `<workgroup-arn>` | The ARN of an agent workgroup | `access-layer/shared/`, `access-layer/aws-mcp-server/`, `cost-envelope/` |
| `<agent-workgroup>` | The name of the agent workgroup | Path READMEs, `cost-envelope/usage-limit-alarm.sh`, `observe/` |
| `agents-wg` | Example workgroup name | `cost-envelope/serverless-ceilings.sh`, `access-layer/custom-mcp-server/sales_metrics_mcp.py` |
| `dev` and `sales_dw` | The example databases. Path, data-layer, act-refund, cost-envelope and observe SQL runs in `dev`. The knowledge base reads `sales_dw` (`kb-redshift-config.json`). Use one database for both if you want the data-layer RLS and masking to apply to the knowledge base; then change `databaseName` and the table names in `kb-redshift-config.json` | Every README with SQL |
| `IAMR:agent-*` names | Database users of agent IAM roles, for example `IAMR:agent-support`. The observe queries find agents with the pattern `'IAMR:agent-%'`, so keep the `agent-` prefix or change the pattern | `data-layer/`, `cost-envelope/`, `observe/`, the path READMEs |
| `<agent-role-name>` | The agent's IAM role | `access-layer/shared/`, `data-layer/redshiftdbroles-tag.sh` and the path READMEs that quote it |
| `<kb-role>` | The knowledge base service role; name it with the `agent-` prefix, for example `agent-kb-sales` | `access-layer/bedrock-knowledge-base/` |
| `refund-proc-owner` and its profile `refund-owner` | The act-refund procedure owner's IAM role, seen as `IAMR:refund-proc-owner`; not an agent, so no `agent-` prefix | `act-refund/` |
| `redshift-monitoring` | Example monitoring role for observe; not an agent, so no `agent-` prefix | `observe/` |
| `<agent-id>` | The value of the `agent-id` tag on the role that calls Bedrock | `cost-envelope/bedrock-budget-action/`, `checklist/attribution-to-budget-action.md` |
| `<model-role-name>` | The IAM role that calls Bedrock; for Redshift ML, the `IAM_ROLE` in `CREATE EXTERNAL MODEL` | `cost-envelope/bedrock-budget-action/`, `checklist/` |
| `<redshift-ml-role-arn>` | The IAM role that Redshift ML uses to call the model | `cost-envelope/model-spend-summarizer.sql`, `cost-envelope/precompute-prompts.sql`, `data-layer/`, `checklist/attribution-to-budget-action.md` |
| `<sns-topic-arn>` | The SNS topic for alarm and budget notifications | `cost-envelope/` |
| `<unload-bucket>` | The bucket that UNLOAD writes to | `observe/export-audit/` |
| `<trail-bucket>` | The bucket for the CloudTrail trail's logs | `observe/export-audit/` |
| `<audit_db>` | The Athena database for the CloudTrail table | `observe/export-audit/cloudtrail-s3-writes.sql` |
| `<cur_database>.<cur_table>` | The Athena table over your CUR 2.0 export | `observe/cost-ledger/bedrock-tokens-cur2.sql` |
| `<monitoring-profile>` | The AWS CLI profile of the monitoring role | `observe/health-checks-and-retention/scheduled_review_cluster.py`, `observe/remaining-configuration.md` |
| `<projection-start-yyyy/MM/dd>` | First day of the trail's data, for example 2026/01/01 | `observe/export-audit/cloudtrail-s3-writes.sql` |
| `developer` | `source_profile` in `aws-config-example.ini` and in the other profiles: your own AWS CLI profile that may assume the agent role | `access-layer/`, `act-refund/` |
| `redshift-agent` and `sales-metrics` | The agent profiles: `redshift-agent` for the Redshift MCP Server and AWS MCP Server paths, `sales-metrics` for the custom MCP server | `access-layer/shared/aws-config-example.ini`, the path READMEs, `observe/attribution/` |
| `agent-lake@s3tablescatalog` | Example S3 Tables catalog database in `cost-envelope/storage-compression.sql`; use your own | `cost-envelope/` |
| Other example names | Listed in each README, for example `etl-unload` and `etl_pipeline` in data-layer, `support_summary_tool` in cost-envelope | Each folder |

## Repository layout

| Folder | What it holds | Who uses it |
| --- | --- | --- |
| [`access-layer/`](access-layer/README.md) | One folder per access path, and the shared controls | IAM and database administrators, developers |
| [`access-layer/shared/`](access-layer/shared/README.md) | The data plane policy, two deny statements and the agent profile used by more than one path | IAM and AWS Organizations administrators |
| [`access-layer/redshift-mcp-server/`](access-layer/redshift-mcp-server/README.md) | Setup for an AI assistant with the Amazon Redshift MCP Server | Developers, platform team |
| [`access-layer/aws-mcp-server/`](access-layer/aws-mcp-server/README.md) | Setup for an AI assistant with the AWS MCP Server and the MCP Proxy for AWS, and an optional deny policy that keeps the agent role on that path | Developers, platform team |
| [`access-layer/custom-mcp-server/`](access-layer/custom-mcp-server/README.md) | A sample MCP server with one fixed, parameterized tool | Application developers |
| [`access-layer/agentcore-custom-agent/`](access-layer/agentcore-custom-agent/README.md) | Identity, policy and limits for a custom agent on Amazon Bedrock AgentCore | Agent developers |
| [`access-layer/bedrock-knowledge-base/`](access-layer/bedrock-knowledge-base/README.md) | The Redshift configuration and service role policy for Amazon Bedrock Knowledge Bases | Application developers |
| [`data-layer/`](data-layer/README.md) | Database roles, row-level security, column privileges, masking, metadata security and export limits | Database administrators |
| [`act-refund/`](act-refund/README.md) | A scoped write procedure with human approval above a threshold | Database administrators, agent developers |
| [`cost-envelope/`](cost-envelope/README.md) | Workgroup ceilings, the usage-limit alarm, per-user limits, Redshift ML precompute, storage compression, and the Bedrock budget action in `bedrock-budget-action/` | Redshift, FinOps and database administrators |
| [`observe/`](observe/README.md) | Attribution, detection, cost ledger, export audit, and health checks and retention, one subfolder each | Platform and security teams |
| [`checklist/`](checklist/README.md) | The before-production checklist and the attribution-to-budget-action test | The team that owns the agent |
| `images/` | The blog post's figures and the diagrams the READMEs embed | Every README |

## Figures from the post

The `images/` folder holds the blog post's figures, in post order. Each figure is also embedded in its folder's README.

| Figure | File |
| --- | --- |
| Figure 1: The layered guardrail model | [images/fig1-layered-model.png](images/fig1-layered-model.png) |
| Figure 2: Who Redshift sees on each access path | [images/fig2-identity-map.png](images/fig2-identity-map.png) |
| Figure 3: Access paths and their guardrails | [images/fig3-access-paths.png](images/fig3-access-paths.png) |
| Figure 4: A scoped action tool, with human approval above a threshold | [images/fig4-act-flow.png](images/fig4-act-flow.png) |
| Figure 5: What the agent sees, keeps, and says | [images/fig5-output-guardrails.png](images/fig5-output-guardrails.png) |
| Figure 6: The cost envelope | [images/fig6-cost-envelope.png](images/fig6-cost-envelope.png) |
| Figure 7: The observe and prove loop | [images/fig7-observe-loop.png](images/fig7-observe-loop.png) |

## Cost

The samples add no new meter for agent access. You pay for what the samples use, at each service's rates:

- Amazon Redshift compute and storage that the queries use ([Amazon Redshift pricing](https://aws.amazon.com/redshift/pricing/)).
- Amazon Bedrock tokens, for Knowledge Bases and Redshift ML ([Amazon Bedrock pricing](https://aws.amazon.com/bedrock/pricing/)).
- AWS CloudTrail data events for the export audit trail ([AWS CloudTrail pricing](https://aws.amazon.com/cloudtrail/pricing/)).
- Amazon CloudWatch alarms and Logs ([Amazon CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/)).
- Amazon Athena queries over CloudTrail and CUR data ([Amazon Athena pricing](https://aws.amazon.com/athena/pricing/)).
- AWS Budgets budgets and actions ([AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/)).
- Amazon S3 storage for the trail logs and exports ([Amazon S3 pricing](https://aws.amazon.com/s3/pricing/)).

## Clean up

Clean up in this order. Each README has the commands for what it created.

1. [observe](observe/README.md#clean-up): the EventBridge rule, the trail, the Athena tables, the scheduled task, the data protection policy, and the `sys:monitor` grant and monitoring role.
2. [cost-envelope](cost-envelope/README.md#groups): the alarm, the usage limits and max capacity, the [Bedrock budget action](cost-envelope/bedrock-budget-action/README.md#clean-up), the precompute objects, the per-user settings and the model tool identity.
3. [act-refund](act-refund/README.md#clean-up): the procedures, the roles, the action identity and the procedure owner identity.
4. The access paths you set up: their database users, path database roles, IAM roles and client configuration. See the Clean up section of [Redshift MCP Server](access-layer/redshift-mcp-server/README.md#clean-up), [AWS MCP Server](access-layer/aws-mcp-server/README.md#clean-up), [custom MCP server](access-layer/custom-mcp-server/README.md#clean-up), [AgentCore custom agent](access-layer/agentcore-custom-agent/README.md#clean-up) or [Bedrock Knowledge Bases](access-layer/bedrock-knowledge-base/README.md#clean-up).
5. [data-layer](data-layer/README.md#groups): masking, the column grant and row-level security policies, `agent_support`, metadata security, and the export grants.
6. [Shared controls](access-layer/shared/README.md#clean-up): the service control policy or identity policy denies on roles you keep, the workgroup tag, and the profile.

Each step removes objects that depend on what a later step removes: `agent_support` is dropped only after no path user holds it, and the shared denies come off last, so agents stay bounded until they're gone.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information. Review every policy with IAM Access Analyzer (`aws accessanalyzer validate-policy`) before you attach it.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
