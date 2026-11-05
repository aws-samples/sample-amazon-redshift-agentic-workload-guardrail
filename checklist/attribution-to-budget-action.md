# Attribution-to-budget-action checklist

Purpose: test the chain from a Bedrock model call to a budget action that stops that one role, end to end, before you rely on it.
Post section: "Control model spend per agent" ("test the attribution-to-budget-action chain end to end before you rely on it; the sample repository has a checklist").
Prerequisites: administrator access in the account that runs the agents, and access to the management (payer) account for cost allocation tags and the CUR 2.0 export. Files referenced below are in this repository.
Placeholders: `<agent-id>`, `<model-role-name>`, `<redshift-ml-role-arn>` (the ARN of the model role, for Redshift ML), `<tool-role>` (the tool identity's database role, for example `support_summary_tool`), `<account-id>`, the dates you record.

The chain runs on billing data. Attribution is aggregated daily, tags can take up to 24 hours to appear and up to 24 more to activate, and budgets are evaluated a few times a day. Plan for two to three days, and treat the result as a period-level brake and a chargeback tool, not a real-time stop.

Each step names the file that implements it. "Billing data" marks steps that you can't complete on the same day.

## 1. Identity: one role per agent or workload

- [ ] Each agent or workload that calls Bedrock has its own IAM role. For Redshift ML, that is the `IAM_ROLE` in `CREATE EXTERNAL MODEL` ([`cost-envelope/precompute-prompts.sql`](../cost-envelope/precompute-prompts.sql)), not the agent's own role.
- [ ] The role may invoke only approved model ARNs; for an inference profile, the profile and each Region's foundation model.
- [ ] Only the tool identity can call the model: `GRANT EXECUTE ON MODEL` to its database role, and, after `REVOKE ASSUMEROLE ON ALL FROM PUBLIC FOR ALL`, `GRANT ASSUMEROLE ON '<redshift-ml-role-arn>' TO ROLE <tool-role> FOR EXTERNAL FUNCTION`. Without that grant the call fails with "does not have ASSUMEROLE permission ... for EXTERNAL FUNCTION".

## 2. Tags

- [ ] Tag every role that calls Bedrock with the same keys (AWS Well-Architected Agentic AI Lens, [AGENTCOST05-BP01](https://docs.aws.amazon.com/wellarchitected/latest/agentic-ai-lens/agentcost05-bp01.html): `agent-id`, `agent-role`, `workflow-id`, `task-type`, `environment`): `aws iam tag-role --role-name <model-role-name> --tags Key=agent-id,Value=<agent-id>`.
- [ ] Make at least one model call with each tagged role. IAM principal tags appear for activation only after the principal has called Bedrock.
- [ ] Billing data: in the management account, activate `iamPrincipal/agent-id` (and the other keys) under Cost allocation tags. Record when each tag shows as Active. This is an organization-wide billing setting. An IAM principal tag key is listed as `iamPrincipal/<key>` with type UserDefined in `aws ce list-cost-allocation-tags`.

## 3. Attribution data

- [ ] Create a CUR 2.0 data export with "Include caller identity (IAM principal) allocation data", and an Athena table over it. Creating the export is a billing change in the management (payer) account.
- [ ] Billing data: after the first delivery, run [`observe/cost-ledger/bedrock-tokens-cur2.sql`](../observe/cost-ledger/bedrock-tokens-cur2.sql) and confirm a row for `<model-role-name>` with `agent_id` = `<agent-id>`. The query folds role sessions into the role.
- [ ] Optional: in Cost Explorer, filter Service = Amazon Bedrock and group by the tag `iamPrincipal/agent-id`.

## 4. Budget and action

- [ ] Check the policies with IAM Access Analyzer: `aws accessanalyzer validate-policy` on [`cost-envelope/bedrock-budget-action/bedrock-budget-action-deny-policy.json`](../cost-envelope/bedrock-budget-action/bedrock-budget-action-deny-policy.json), [`cost-envelope/bedrock-budget-action/budget-action-execution-role-policy.json`](../cost-envelope/bedrock-budget-action/budget-action-execution-role-policy.json) (identity policies) and [`cost-envelope/bedrock-budget-action/budget-action-execution-role-trust.json`](../cost-envelope/bedrock-budget-action/budget-action-execution-role-trust.json) (`--policy-type RESOURCE_POLICY --validate-policy-resource-type AWS::IAM::AssumeRolePolicyDocument`).
- [ ] Create the deny policy, the execution role, the budget and the action with the commands in blocks `# 1.` to `# 4.` of [`cost-envelope/bedrock-budget-action/bedrock-budget-action.sh`](../cost-envelope/bedrock-budget-action/bedrock-budget-action.sh), quoted in the [Bedrock budget action README](../cost-envelope/bedrock-budget-action/README.md) (one budget per agent tag; the action at 100% attaches the deny policy to `<model-role-name>`). The action stays in STANDBY until the threshold is crossed.
- [ ] Subscribe someone to the SNS topic, or route it to a ticket queue. When the action runs, the topic receives "AWS Budgets Action: An action has successfully executed".

## 5. Prove the stop works before you need it

- [ ] Attach the deny policy by hand to `<model-role-name>`, or let a test budget fire, then run the model call: Redshift ML returns `Error sent from Bedrock: User: arn:aws:sts::<account-id>:assumed-role/<model-role-name>/RedshiftIamRoleSession is not authorized to perform: bedrock:InvokeModel`.
- [ ] Check that the action itself can run, not only the policy: a test budget whose limit is already exceeded (for example Service = Amazon Bedrock, annual, $0.01) fires at its first evaluation, through the same execution role and definition.
- [ ] Reverse it: `aws budgets execute-budget-action ... --execution-type REVERSE_BUDGET_ACTION` detaches the policy and sets the status to REVERSE_SUCCESS. Detaching the policy by hand leaves the action in EXECUTION_SUCCESS, so use the reverse command to keep the budget's history accurate.
- [ ] Run the model call again and confirm it succeeds.

## 6. Operate it

- [ ] Billing data: after the first period with real spend, check `aws budgets describe-budget-action-histories` for the per-agent budget, and compare the time the action ran with the time spend crossed 100% in CUR 2.0. The gap is your exposure window.
- [ ] Decide who may reverse the action within the period and how, and who approves raising the budget. Consider `--approval-model MANUAL` for agents where an automatic stop is worse than the overspend.
- [ ] Keep the compute side of the same agent in view: [`observe/cost-ledger/compute-ledger.sql`](../observe/cost-ledger/compute-ledger.sql) per database user and label, and the workgroup usage-limit alarm ([`cost-envelope/usage-limit-alarm.sh`](../cost-envelope/usage-limit-alarm.sh)).
