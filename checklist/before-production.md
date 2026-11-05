# Before production

The checklist from the post's conclusion. The attribution-to-budget-action checklist that the post's model spend section mentions is in [attribution-to-budget-action.md](attribution-to-budget-action.md).

To get started:

1. Connect safely. Set up the Amazon Redshift MCP Server in read-only mode with a per-agent IAM role, and install the redshift-guide skill from the Agent Toolkit for AWS. Files: [`access-layer/`](../access-layer/) (pick your path, for example [`access-layer/redshift-mcp-server/`](../access-layer/redshift-mcp-server/)).

2. Bound the data. Grant the agent's database role only the tables and columns it needs, attach RLS and masking policies, and revoke ASSUMEROLE and CREATE from PUBLIC. Test metadata security on a non-production workgroup first. Files: [`data-layer/`](../data-layer/).

3. Bound the spend. Set a statement timeout, max capacity, and a daily usage limit on the agent workgroup, and test the usage-limit alarm end to end. Files: [`cost-envelope/`](../cost-envelope/).

