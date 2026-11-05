# Act pattern: a scoped write tool with human approval

The agent's only write is one stored procedure, `support.refund_order`, which checks every request itself: small refunds go through, larger ones wait for a person, and anything over the cap or over what's left on the order is rejected with nothing written. The agent's database user can run that procedure and nothing else, so it can't go around the checks.
In the accompanying blog post: section "Scope every write, and keep a human in the loop where it matters".

## When to use it

When an agent must take one consequential action, such as a refund. It addresses excessive agency. Not every write needs a person: refunds up to $100 run without one, refunds above $100 and up to $500 wait for a person to approve, and anything over $500 or over what's left on the order is rejected. It's normally used by the agent's action tool, a custom MCP server tool or a Lambda target behind AgentCore Gateway, which calls `CALL support.refund_order` through the Data API under its own IAM role, separate from the agent's read path.

## Who runs it

- An administrator (a superuser, or a user with `sys:secadmin` for the row-level security lines), for Set up step 0 (b), part 2 and step 4.
- The procedure owner `IAMR:refund-proc-owner`, a non-superuser that holds `refund_owner`, for part 1. A superuser owner would bypass row-level security and hide why `rls_all_orders` is needed.
- An IAM administrator, for the two IAM roles.
- People in `refund_approvers`, for `support.approve_refund`.

## Prerequisites

- The schemas `support` and `sales`, and `sales.orders` with the example order IDs used in Verify (1001, 1002 with a total of 80.50, and 1007), from the example schema in the [root README](../README.md#prerequisites).
- Optional, for the first Verify row: row-level security on `sales.orders`, from [data-layer Rows, columns and values](../data-layer/README.md#rows-columns-and-values).
- The procedure owner. Nothing outside this README creates it, so Set up step 0 does.
- The action identity: the IAM role `agent-support-actions`, created like a path role in step 1 of the [custom MCP server](../access-layer/custom-mcp-server/README.md#1-create-the-iam-role) or [AgentCore custom agent](../access-layer/agentcore-custom-agent/README.md#1-create-the-iam-role) path, with [`../access-layer/shared/agent-data-plane-policy.json`](../access-layer/shared/agent-data-plane-policy.json) attached (Set up step 1).
- Your own AWS CLI profile (`developer` in the examples) whose role may assume `refund-proc-owner`.

All SQL on this page runs in database `dev`.

Placeholders:
- `IAMR:agent-support-actions`: the action identity's database user, created at its first sign-in.
- `refund-proc-owner`: the procedure owner's IAM role, seen as `IAMR:refund-proc-owner`. It has no `agent-` prefix because it isn't an agent.
- `refund-owner`: the owner's AWS CLI profile.
- `<developer-role>`: the IAM role behind your `developer` profile.
- `<approver-user>`: the database user of each person who approves refunds.
- `<agent-workgroup>` and `<agent-workgroup-id>`: the agent workgroup's name and its ID, in `agent-data-plane-policy.json`; `<id>`: the statement ID that `execute-statement` returns.
- `111122223333` and `us-east-1`: the example account ID and Region.
- The thresholds 100 and 500 in `refund_procedures.sql`.

## How it works

![The Act pattern in four numbered steps. A support agent calls 1, the refund_order tool, which runs as an action identity that can call one procedure and read no tables. 2, the support.refund_order procedure in Redshift, checks the order and caps the amount at what is left and $500. Refunds up to $100 are approved, refunds from $100 to $500 wait for approval, and larger ones are rejected with an error and nothing written. 3, approve_refund, can be run only by refund_approvers, records the approver, and rejects self-approval. 4, the payment process, pays approved refunds only. A band explains that the agent's identity has no table privileges, so it can't go around the procedure.](../images/fig4-act-flow.png)

The diagram below shows the identities: who can run what, and as whom each procedure runs.

![Identities in the act pattern. The agent's action tool role signs in as IAMR:agent-support-actions, whose agent_refunds role can only execute refund_order. That SECURITY DEFINER procedure runs as its owner, IAMR:refund-proc-owner, whose refund_owner role reads orders through the rls_all_orders policy, and approves refunds up to 100 dollars, queues refunds up to 500 dollars and rejects larger ones. People in the refund_approvers role can only execute approve_refund, which rejects self-approval. Neither role has privileges on the refunds table.](../images/act-refund-identities.png)

- `support.refund_order` is `SECURITY DEFINER`: it runs with its owner's privileges and row-level security policies. It locks `support.refunds`, checks the amount against what's left to refund on the order and the $500 cap, approves refunds up to $100, and queues larger ones as `pending_approval`.
- `support.approve_refund` is the human step: only `refund_approvers` can run it, and nobody can approve their own request.
- `agent_refunds` has only `EXECUTE` on `refund_order`, and `refund_approvers` only `EXECUTE` on `approve_refund`. Neither has privileges on `support.refunds`.
- The procedure reads `sales.orders` with its owner's row-level security policies, so the file attaches `rls_all_orders` to `refund_owner`.

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`refund_procedures.sql`](refund_procedures.sql) | Part 1 creates `support.refunds` and the two `SECURITY DEFINER` procedures; part 2 creates `agent_refunds` and `refund_approvers`, their `EXECUTE` grants, and `rls_all_orders` for `refund_owner` | Set up steps 2 and 3 | part 1 runs as `IAMR:refund-proc-owner`; part 2 run as a database administrator |

## Set up

Run each command block from the repository root; each one starts with the `cd` it needs.

### 0. Create the procedure owner

The owner signs in with an IAM role, so no database password exists.

(a) As an IAM administrator, create the role `refund-proc-owner`, which your developer role can assume, and give it the data plane policy (for `GetCredentials` on the workgroup) and the query editor v2 permissions it needs in step 2. Replace `111122223333`, `us-east-1` and `<agent-workgroup-id>` in `agent-data-plane-policy.json` first.

```bash
cd act-refund
cat > refund-proc-owner-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "DeveloperAssumesOwnerRole", "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::111122223333:role/<developer-role>" },
      "Action": "sts:AssumeRole" }
  ]
}
EOF
aws accessanalyzer validate-policy --policy-type RESOURCE_POLICY \
  --validate-policy-resource-type AWS::IAM::AssumeRolePolicyDocument \
  --policy-document file://refund-proc-owner-trust.json --query "findings[?findingType=='ERROR']"
aws iam create-role --role-name refund-proc-owner \
  --assume-role-policy-document file://refund-proc-owner-trust.json
aws iam put-role-policy --role-name refund-proc-owner --policy-name agent-data-plane \
  --policy-document file://../access-layer/shared/agent-data-plane-policy.json
aws iam attach-role-policy --role-name refund-proc-owner \
  --policy-arn arn:aws:iam::aws:policy/AmazonRedshiftQueryEditorV2NoSharing
```

Add the owner's profile to `~/.aws/config`:

```ini
[profile refund-owner]
role_arn = arn:aws:iam::111122223333:role/refund-proc-owner
source_profile = developer
duration_seconds = 3600
```

Then sign in once through the Data API, which creates the database user:

```bash
cd act-refund
aws redshift-data execute-statement --workgroup-name <agent-workgroup> --database dev \
  --sql "SELECT current_user" --profile refund-owner --region us-east-1
aws redshift-data describe-statement --id <id> --profile refund-owner --region us-east-1 --query Status
aws redshift-data get-statement-result --id <id> --profile refund-owner --region us-east-1 \
  --query "Records[0][0].stringValue"
```

What this does:
- Writes the generated trust file `refund-proc-owner-trust.json` in this folder (don't commit it), checks it (`[]` means no errors) and creates the role.
- Adds the inline policy `agent-data-plane` and attaches the AWS managed policy [`AmazonRedshiftQueryEditorV2NoSharing`](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonRedshiftQueryEditorV2NoSharing.html), which query editor v2 needs ([Configuring your AWS account](https://docs.aws.amazon.com/redshift/latest/mgmt/query-editor-v2-getting-started.html)).
- Run `describe-statement` until it shows `"FINISHED"`; `get-statement-result` returns `"IAMR:refund-proc-owner"`. The first sign-in creates the database user, with no privileges yet.

(b) As a database administrator, create the owner's database role and grants. Privileges go to the role, never to the user. The owner creates and so owns `support.refunds`; `CREATE` through a role it holds is enough for that.

```sql
CREATE ROLE refund_owner;
GRANT USAGE, CREATE ON SCHEMA support TO ROLE refund_owner;
GRANT USAGE ON SCHEMA sales TO ROLE refund_owner;
GRANT SELECT ON sales.orders TO ROLE refund_owner;
GRANT ROLE refund_owner TO "IAMR:refund-proc-owner";
```

### 1. Create the action identity

Create the IAM role `agent-support-actions` for the action tool like step 1 of the [custom MCP server path](../access-layer/custom-mcp-server/README.md#1-create-the-iam-role), trusting whatever runs the tool, then attach the data plane policy:

```bash
cd act-refund
aws iam put-role-policy --role-name agent-support-actions --policy-name agent-data-plane \
  --policy-document file://../access-layer/shared/agent-data-plane-policy.json
```

Sign in once as that role through the Data API (with the tool itself, or with a profile for the role as in step 0 (a)), so that Redshift creates the database user `IAMR:agent-support-actions`. Keep this role separate from the agent's read path: it signs in only to call the procedure.

### 2. Run part 1 as the procedure owner

Run part 1 of [`refund_procedures.sql`](refund_procedures.sql), up to the `-- Part 2` comment, in Amazon Redshift query editor v2:

1. Sign in to the AWS Management Console and switch to the `refund-proc-owner` role. See [Switch from a user to an IAM role (console)](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-console.html).
2. Open query editor v2 and connect to the workgroup with **Federated user**, database `dev`. See [Connecting to an Amazon Redshift database](https://docs.aws.amazon.com/redshift/latest/mgmt/query-editor-v2-connecting.html).
3. Run `SELECT current_user;` and check that it returns `IAMR:refund-proc-owner`.
4. Run part 1. Query editor v2 runs the `CREATE PROCEDURE` bodies between `$$` delimiters as written.

What this does:
- Creates `support.refunds`, `support.refund_order` and `support.approve_refund`, all owned by `IAMR:refund-proc-owner`, and revokes `EXECUTE` on both procedures from `PUBLIC`.

### 3. Run part 2 as an administrator

Run part 2 of `refund_procedures.sql`, from the `-- Part 2` comment to the end, as a database administrator. Its `GRANT ROLE agent_refunds TO "IAMR:agent-support-actions";` line needs the action identity's database user from step 1; if your action identity has another name, change the line first.

What this does:
- Creates `agent_refunds` and `refund_approvers`, with `USAGE` on schema `support` and `EXECUTE` on one procedure each.
- Grants `agent_refunds` to the action identity.
- Creates `rls_all_orders` and attaches it to `sales.orders` for `refund_owner`, so the procedure sees every order when row-level security is on.

### 4. Grant the approver role

As a database administrator, grant `refund_approvers` to each person who approves refunds:

```sql
GRANT ROLE refund_approvers TO "<approver-user>";
```

## Verify

Run these as the action identity unless noted. A `CALL` returns no rows, and the action identity can't read `support.refunds`, so check the rows a call writes as a database administrator with `SELECT * FROM support.refunds;`.

| Check | Run as | Expected result |
| --- | --- | --- |
| `CALL support.refund_order(1001, 50)` before `rls_all_orders` is attached (row-level security on `sales.orders`) | the action identity | `Order 1001 not found` |
| `CALL support.refund_order(1001, 50)` | the action identity | succeeds; `support.refunds` has a row with status `approved` |
| `CALL support.refund_order(1007, 150)` | the action identity | succeeds; `support.refunds` has a row with status `pending_approval` |
| `CALL support.refund_order(1007, 600)` | the action identity | `Refund of 600 is outside the allowed range for order 1007` |
| `refund_order(1002, 50)`, then `refund_order(1002, 40)` on an 80.50 order | the action identity | the second call fails with `Refund of 40 is outside the allowed range for order 1002`: more than what's left |
| `SELECT` or `INSERT` on `support.refunds`, `CALL support.approve_refund(...)` | the action identity | `permission denied` |
| `CALL support.approve_refund(<pending id>)` | an approver | status `approved`, `approved_by` set |
| `CALL support.approve_refund(<own id>)` | an approver who requested the refund | `A refund cannot be approved by its requester` |
| Two calls at the same time on one order whose total would exceed it | the action identity | the lock serializes them: one succeeds, and the call that runs second fails with `Refund of ... is outside the allowed range for order ...` |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `Order 1001 not found` for an order that exists | Row-level security is on for `sales.orders` and no policy is attached for the owner's role `refund_owner` | Run part 2, which attaches `rls_all_orders` |
| `permission denied` on `support.refunds` for the action identity | By design: the agent can only call the procedure | Nothing to fix |
| `A refund cannot be approved by its requester` | By design: nobody approves their own request | Have another approver run it |
| `permission denied for schema support` when running part 1 | Step 0 (b) didn't run, or part 1 ran as a user that doesn't hold `refund_owner` | Run step 0 (b); check `SELECT current_user` in the same session, which must return `IAMR:refund-proc-owner` |
| `AccessDenied` calling `AssumeRole` with the `refund-owner` profile, or when switching role | The trust policy's principal isn't your developer role's full ARN. For IAM Identity Center roles that ARN includes the `aws-reserved/sso.amazonaws.com/` path, followed by the Region of your IAM Identity Center instance unless it's `us-east-1` | `aws sts get-caller-identity --profile developer` shows the role name; `aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ --query "Roles[].Arn"` shows the full ARN to put in the trust policy |

## Clean up

As a database administrator, drop the procedures, the table, the policy and the roles:

```sql
DETACH RLS POLICY rls_all_orders ON sales.orders FROM ROLE refund_owner;
DROP RLS POLICY rls_all_orders;
DROP PROCEDURE support.refund_order(BIGINT, DECIMAL(10,2));
DROP PROCEDURE support.approve_refund(BIGINT);
DROP TABLE support.refunds;
DROP ROLE agent_refunds FORCE;
DROP ROLE refund_approvers FORCE;
DROP ROLE refund_owner FORCE;
```

Then drop the two database users:

```sql
DROP USER "IAMR:agent-support-actions";
DROP USER "IAMR:refund-proc-owner";
```

Delete the two IAM roles. `delete-role` fails with `DeleteConflict` while a role has any policy, so delete its inline policies (`agent-data-plane` on each) and detach its managed policies first:

```bash
cd act-refund
aws iam list-role-policies --role-name agent-support-actions
aws iam delete-role-policy --role-name agent-support-actions --policy-name agent-data-plane
aws iam list-attached-role-policies --role-name agent-support-actions
aws iam delete-role --role-name agent-support-actions
aws iam list-role-policies --role-name refund-proc-owner
aws iam delete-role-policy --role-name refund-proc-owner --policy-name agent-data-plane
aws iam list-attached-role-policies --role-name refund-proc-owner
aws iam detach-role-policy --role-name refund-proc-owner \
  --policy-arn arn:aws:iam::aws:policy/AmazonRedshiftQueryEditorV2NoSharing
aws iam delete-role --role-name refund-proc-owner
rm refund-proc-owner-trust.json
```

Run `delete-role-policy` once for each name that `list-role-policies` returns. For `agent-support-actions`, `list-attached-role-policies` is expected to return an empty list; for `refund-proc-owner`, it lists the query editor v2 policy that `detach-role-policy` removes. Finally, remove the `[profile refund-owner]` block from `~/.aws/config`.

## Used by

- The [custom MCP server](../access-layer/custom-mcp-server/) path, when its server adds an action tool.
- The [AgentCore custom agent](../access-layer/agentcore-custom-agent/) path, for a Lambda action tool behind AgentCore Gateway.
