# Checklists: before production, and model spend attribution

Two ordered checklists: the steps to take before an agent goes to production, and an end-to-end test of the chain from a Bedrock model call to a budget action that stops one agent's role. Each step links the folder or file that implements it.
In the accompanying blog post: sections "Conclusion" (to get started) and "Control model spend per agent".

## When to use it

Before an agent goes to production, and when you test the attribution of model spend end to end before you rely on a per-agent budget. The checklists are themselves the verification steps, so this README has no Set up, Verify or Clean up of its own: each step points to the README that has them. There's no diagram either: the checklists are ordered steps, and a diagram would repeat them.

## Who runs it

- The team that owns the agent, for `before-production.md`.
- An administrator in the account that runs the agents and a management-account (payer) administrator, for `attribution-to-budget-action.md`, which needs cost allocation tags and a CUR 2.0 export.

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`before-production.md`](before-production.md) | The three get-started steps from the blog post: connect safely, bound the data, bound the spend, each with a link to the folder that implements it | Before an agent goes to production | the team that owns the agent |
| [`attribution-to-budget-action.md`](attribution-to-budget-action.md) | End-to-end test of model-call attribution to a budget action: identity, tags, attribution data, budget and action, proof that the stop works, and operation. Plan for two to three days of billing data | Before you rely on the [Bedrock budget action](../cost-envelope/bedrock-budget-action/README.md) | administrator in the agent account, with management-account access |

## Used by

- The five access paths: [Redshift MCP Server](../access-layer/redshift-mcp-server/), [AWS MCP Server](../access-layer/aws-mcp-server/), [custom MCP server](../access-layer/custom-mcp-server/), [AgentCore custom agent](../access-layer/agentcore-custom-agent/), [Bedrock Knowledge Bases](../access-layer/bedrock-knowledge-base/).
- [data-layer](../data-layer/README.md) and [cost-envelope](../cost-envelope/README.md), whose setup the checklists walk through.
