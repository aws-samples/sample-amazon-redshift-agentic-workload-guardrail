# Data layer: decide what the agent can reach

The data layer is the database side of least privilege. On every access path the agent's SQL runs as one database user, and that user's privileges decide what the SQL can read, see or copy, whatever the agent was asked to do. It addresses excessive agency: a prompt can change what the agent asks for, but not what its database user can reach.
In the accompanying blog post: sections "Data layer: decide what the agent can reach" and "What the agent keeps: database-side exports and copies".

Each access path README covers the IAM policy, the other scope of least privilege. This folder covers the database permissions: one database role per agent, rows, columns and values, metadata, lakehouse tables, and exports.

![The data layer between the agent's database user and the data. The mapped database user gets its privileges from one database role, granted directly or through the RedshiftDbRoles tag. Each query then passes metadata security, table and column privileges, row-level security and masking before it reaches managed storage or Iceberg tables governed by Lake Formation. A separate branch shows export controls: UNLOAD only for pipeline roles, no CREATE in the public schema, and no datashare privileges for agents.](../images/data-layer-controls.png)

1. Mapped database user and database role: the agent's IAM role signs in as a database user such as `IAMR:agent-support`, which gets its privileges from the database role `agent_support` (Database identity and roles).
2. Every query passes: metadata security, table and column privileges, row-level security and masking (Metadata security; Rows, columns and values).
3. Data: Redshift managed storage, or Apache Iceberg tables governed by Lake Formation permissions (Lakehouse tables).
4. Side branch: export controls, so UNLOAD runs only for pipeline roles and agents can't create tables in `public` or share data (Exports and copies).

## Groups

| Group | What it controls | Run as | Files |
| --- | --- | --- | --- |
| [Database identity and roles](#database-identity-and-roles) | Which database role the agent's database user holds: a `GRANT ROLE`, the `RedshiftDbRoles` IAM role tag, or an STS session tag | Database administrator; IAM administrator for the tag | `agent-role.sql`, `redshiftdbroles-tag.sh`, `redshiftdbroles-tag-permissions.json`, `redshiftdbroles-verify.sql` |
| [Rows, columns and values](#rows-columns-and-values) | Which rows of `sales.orders`, which columns of `sales.customers`, and how much of `sales.payments.card_number` the role sees | Superuser, or a user with `sys:secadmin` | `fine-grained-access.sql` |
| [Metadata security](#metadata-security) | Which tables and schemas users see in the catalog | Superuser | `metadata-security.sql` |
| [Lakehouse tables](#lakehouse-tables) | Lake Formation permissions on Iceberg tables, federated permissions, datashares | Lake Formation administrator | none (configured outside this repository) |
| [Exports and copies](#exports-and-copies) | Who can UNLOAD, and who can create tables in `public` | Superuser | `exports-and-copies.sql` |

Clean up in this order: Exports and copies, Metadata security, Rows, columns and values, then Database identity and roles.

Each access path README says which database user receives `agent_support` on that path. The SQL in this README runs in database `dev`.

## Database identity and roles

### When to use it

On every access path. Privileges go to one database role per agent, never to the user, so you can see and change what an agent can reach in one place, and a second user for the same agent gets the same privileges. It addresses excessive agency. Use the `RedshiftDbRoles` tag on Redshift Serverless when you'd rather map IAM roles to database roles at sign-in than run `GRANT ROLE` for each agent user.

### Who runs it

- A database administrator, for `agent-role.sql` and the `GRANT ROLE` variant.
- An IAM administrator, for the `RedshiftDbRoles` tag and its permissions policy.
- The agent itself, for part 1 of `redshiftdbroles-verify.sql`.

### Prerequisites

- The example schema `sales.orders` and `sales.payments` (see the [root README](../README.md#prerequisites)).
- Variant A: the agent's database user exists. It's created at the agent's first sign-in, in step 3 of your path README: [Redshift MCP Server](../access-layer/redshift-mcp-server/README.md#3-create-the-database-user), [AWS MCP Server](../access-layer/aws-mcp-server/README.md#3-create-the-database-user), [custom MCP server](../access-layer/custom-mcp-server/README.md#3-create-the-database-user), [AgentCore custom agent](../access-layer/agentcore-custom-agent/README.md#3-create-the-database-user).
- Variants B and C: the agent's IAM role exists (step 1 of your path README), and step 1 below has run. The tag maps the IAM role to `agent_support` at sign-in; it doesn't create the database role, and a role name that doesn't exist in the database is ignored.

Placeholders:
- `<agent-role-name>`: the agent's IAM role, for example `agent-support`.
- `agent_support`: the example database role. Use one role per agent.
- `IAMR:agent-support`: the example database user in `agent-role.sql`. Use the user name on your path; each path README lists it in its "Database identity on this path" table.

### How it works

This group is the "Mapped database user" and "Database role agent_support" part of the diagram above. Redshift maps an IAM role that signs in through `GetCredentials` to the database user `IAMR:<role name>`. That user holds `agent_support` in one of three ways:

- Variant A, `GRANT ROLE` after the first sign-in: stored as a grant in the database.
- Variant B, the `RedshiftDbRoles` IAM role tag on Redshift Serverless: a session role. It holds for sessions that sign in while the tag is set, isn't stored as a grant, and ends at the next sign-in after you remove the tag.
- Variant C, an STS session tag named `RedshiftDbRoles` set when the application assumes the role: the same mapping, for that session only.

See [Defining database roles to grant to federated users in Amazon Redshift Serverless](https://docs.aws.amazon.com/redshift/latest/mgmt/redshift-iam-access-federated-db-roles.html) in the Amazon Redshift Management Guide.

### Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`agent-role.sql`](agent-role.sql) | Creates the database role `agent_support` with `USAGE` on schema `sales` and `SELECT` on `sales.orders` and `sales.payments`; its last line grants the role to `IAMR:agent-support` | Set up step 1 (lines 1 to 4) and variant A (line 7) | run as a database administrator |
| [`redshiftdbroles-tag.sh`](redshiftdbroles-tag.sh) | AWS CLI lines that tag the agent's IAM role with `RedshiftDbRoles=agent_support`, attach the tag permissions, list the role's tags, and remove the tag. Quoted below, never run as a script | Set up variant B, Verify, Clean up | run as an IAM administrator |
| [`redshiftdbroles-tag-permissions.json`](redshiftdbroles-tag-permissions.json) | IAM policy with `tag:GetResources` and `tag:GetTagKeys`, which the Redshift guide lists for roles that sign in with IAM credentials | Inline policy `redshiftdbroles-tag-read` on the agent role (variant B) | attached to the agent IAM role |
| [`redshiftdbroles-verify.sql`](redshiftdbroles-verify.sql) | Part 1 checks from the agent's own session that it holds `agent_support`; part 2 shows the role's grants | Verify | part 1 runs as `IAMR:<agent-role-name>`; part 2 run as a database administrator |

### Set up

Run each block from the repository root; each one starts with the `cd` it needs. Replace the placeholders after you copy the lines.

#### 1. Create the database role

As a database administrator, run lines 1 to 4 of [`agent-role.sql`](agent-role.sql). Skip this step if another path already created `agent_support`.

```sql
-- One database role per agent: privileges go to the role, never to the user
CREATE ROLE agent_support;
GRANT USAGE ON SCHEMA sales TO ROLE agent_support;
GRANT SELECT ON sales.orders, sales.payments TO ROLE agent_support;
```

What this does:
- Creates `agent_support` with `USAGE` on schema `sales` and `SELECT` on `sales.orders` and `sales.payments`.

#### 2. Give the role to the agent's database user

Use one of three variants.

Variant A, `GRANT ROLE`, as a database administrator after the agent's first sign-in. Line 7 of `agent-role.sql` grants it to the AgentCore path's user; put your path's user name in the quotes:

```sql
GRANT ROLE agent_support TO "IAMR:agent-support";
```

Variant B, the `RedshiftDbRoles` tag, as an IAM administrator. Lines under the tag and permissions comments of `redshiftdbroles-tag.sh`, quoted as written:

```bash
cd data-layer
aws iam tag-role --role-name <agent-role-name> \
  --tags Key=RedshiftDbRoles,Value=agent_support
aws iam put-role-policy --role-name <agent-role-name> \
  --policy-name redshiftdbroles-tag-read \
  --policy-document file://redshiftdbroles-tag-permissions.json
```

Then let the agent sign in again (a new Data API call or a new connection): the tag is read at sign-in. Separate several database roles with colons, for example `agent_support:agent_reports`.

Variant C, an STS session tag: when the agent's application assumes its IAM role, it passes a session tag with the key `RedshiftDbRoles` and the value `agent_support`. The role's trust policy must allow `sts:TagSession` for the caller. See the link under How it works.

What this does:
- Variant A stores a grant: `SHOW GRANTS` and SVV_USER_GRANTS list it.
- Variant B maps the IAM role to `agent_support` for every session that signs in while the tag is set. Nothing is stored in the database.
- Variant B's `redshiftdbroles-tag-read` policy lets drivers that sign in with IAM credentials read the tag. Sign-in through the Data API maps the role without it.

### Verify

Run part 1 of [`redshiftdbroles-verify.sql`](redshiftdbroles-verify.sql) as the agent, in a session that signed in after the grant or the tag, and part 2 as a database administrator. For variant B, audit the tag with the `list-role-tags` line of `redshiftdbroles-tag.sh`, quoted as written:

```bash
cd data-layer
aws iam list-role-tags --role-name <agent-role-name>
```

| Check | Run as | Expected result |
| --- | --- | --- |
| `SELECT current_user;` | the agent | `IAMR:<agent-role-name>` |
| `SELECT user_is_member_of(current_user, 'agent_support');` | the agent | `true` |
| `SELECT has_table_privilege('sales.orders', 'select');` | the agent | `true` |
| `SHOW GRANTS FOR ROLE agent_support;` | database administrator | `USAGE` on `sales`, `SELECT` on `sales.orders` and `sales.payments` |
| `aws iam list-role-tags` (variant B) | IAM administrator | a tag with `Key` `RedshiftDbRoles` and `Value` `agent_support` |

The session role from variant B doesn't appear in SVV_USER_GRANTS, `SHOW GRANTS FOR "IAMR:..."` or `HAS_TABLE_PRIVILEGE('IAMR:...', ...)` run by someone else. Audit the IAM tag and `SHOW GRANTS FOR ROLE agent_support` instead. For the same reason, [`observe/detection/agent-table-privileges.sql`](../observe/detection/agent-table-privileges.sql) doesn't list privileges that come from the tag.

### Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `permission denied for schema sales` after tagging (variant B) | `agent_support` doesn't exist because step 1 didn't run, or the agent hasn't signed in again since the tag change | Run step 1, then sign in again |
| `permission denied for schema sales` after `untag-role` | Expected: the next sign-in no longer gets the session role | Nothing to fix if you meant to remove it; otherwise tag the role again or use variant A |
| `user_is_member_of` returns `false` | The session signed in before the grant or the tag, or variant A granted the role to another user name | Sign in again; check `SELECT current_user` against the name in the `GRANT ROLE` |
| `DROP ROLE agent_support` fails because the role is still granted to a user | A user still holds the role | Revoke it from every user first (Clean up step 2), or run that path's cleanup |

### Clean up

Run this after the Rows, columns and values cleanup, and after the access path cleanups, which drop their own users. As a database administrator:

```sql
-- 1. Which users still hold the role (expected: no rows after the access path cleanups)
SELECT user_name FROM svv_user_grants WHERE role_name = 'agent_support';
-- 2. For each user listed, for example the user agent-role.sql grants it to:
REVOKE ROLE agent_support FROM "IAMR:agent-support";
-- 3. Remove the role's own grants, then the role
REVOKE SELECT ON sales.orders, sales.payments FROM ROLE agent_support;
REVOKE USAGE ON SCHEMA sales FROM ROLE agent_support;
DROP ROLE agent_support;
```

For an IAM role you keep after variant B (a deleted role takes its tags and inline policies with it), remove the tag with the `untag-role` line of `redshiftdbroles-tag.sh`, quoted as written:

```bash
cd data-layer
aws iam untag-role --role-name <agent-role-name> --tag-keys RedshiftDbRoles
```

Then remove the tag permissions policy from the same role:

```bash
cd data-layer
aws iam delete-role-policy --role-name <agent-role-name> --policy-name redshiftdbroles-tag-read
```

### Used by

All five access paths: [Redshift MCP Server](../access-layer/redshift-mcp-server/), [AWS MCP Server](../access-layer/aws-mcp-server/) and [AgentCore custom agent](../access-layer/agentcore-custom-agent/) use `agent_support`; the [custom MCP server](../access-layer/custom-mcp-server/) and [Bedrock Knowledge Bases](../access-layer/bedrock-knowledge-base/) paths create their own database roles the same way.

## Rows, columns and values

### When to use it

When an agent may read a table but not every row, column or value in it: for example a support agent that serves one region, must not see customer PII, and may see only the last four digits of a card number. It addresses excessive agency, and it applies to every query the role runs, whatever the prompt.

### Who runs it

A superuser, or a user with the `sys:secadmin` role for the row-level security and masking statements. The column grant needs a superuser or the table owner.

### Prerequisites

- `agent_support` exists ([Database identity and roles](#database-identity-and-roles), step 1).
- The tables `sales.orders` (with a `region` column), `sales.customers` and `sales.payments` (with `card_number VARCHAR(16)`), from the example schema in the [root README](../README.md#prerequisites).
- Run `fine-grained-access.sql` in each database whose `sales.orders` your agents read (`dev` for the Data API paths; `sales_dw` too if the knowledge base should use `rls_region_west`). RLS and masking policies belong to one database.

Placeholders: none. Example names: `rls_region_west`, `mask_card_last4`, and the value `'west'`.

### How it works

This group is the "Table and column privileges", "Row-level security" and "Masking" boxes of the diagram above. The policies attach to the database role, not to a user, so every user that holds `agent_support` gets them. See [Row-level security](https://docs.aws.amazon.com/redshift/latest/dg/t_rls.html) and [Dynamic data masking](https://docs.aws.amazon.com/redshift/latest/dg/t_ddm.html) in the Amazon Redshift Database Developer Guide.

### Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`fine-grained-access.sql`](fine-grained-access.sql) | Row-level security policy `rls_region_west` on `sales.orders`, a four-column grant on `sales.customers`, and masking policy `mask_card_last4` on `sales.payments.card_number`, all for `agent_support` | Set up | run as a database administrator (superuser or `sys:secadmin`) |

### Set up

> [!WARNING]
> Row-level security makes a table default-deny: once it's on for `sales.orders`, a role with no policy attached sees no rows. Attach policies for the other roles that read the table before you run the file, for example `rls_all_orders` for the procedure owner in [act-refund](../act-refund/README.md).

Run [`fine-grained-access.sql`](fine-grained-access.sql) as is, in each database the prerequisites name. It has three parts.

#### Row-level security

`CREATE RLS POLICY rls_region_west` keeps rows where `region = 'west'`, `ATTACH RLS POLICY` attaches it to `sales.orders` for `agent_support`, and `ALTER TABLE sales.orders ROW LEVEL SECURITY ON` turns it on.

#### Column privileges

`GRANT SELECT (customer_id, segment, region, signup_date) ON sales.customers TO ROLE agent_support` grants four columns and no PII columns.

#### Dynamic data masking

`CREATE MASKING POLICY mask_card_last4` returns `XXXXXXXXXXXX` followed by the last four digits, and `ATTACH MASKING POLICY` applies it to `sales.payments(card_number)` for `agent_support`.

### Verify

Test as the agent: superusers and users with `sys:secadmin` bypass row-level security.

| Check | Run as | Expected result |
| --- | --- | --- |
| `SELECT DISTINCT region FROM sales.orders;` | the agent | only `west` |
| `SELECT * FROM sales.customers;` | the agent | only the four granted columns: with SELECT on some columns of a table, `SELECT *` returns only those columns |
| `SELECT email FROM sales.customers;` | the agent | `permission denied for relation customers` |
| `SELECT card_number FROM sales.payments LIMIT 5;` | the agent | `XXXXXXXXXXXX` followed by four digits |
| `SELECT is_rls_on FROM svv_rls_relation WHERE relname = 'orders';` | database administrator | `true` |

### Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `rls policy "rls_region_west" already exists` | The file already ran in this database, for example for another path | Nothing to change: the policies attach to `agent_support` |
| Another application sees no rows of `sales.orders` | Row-level security is on and that application's role has no policy attached | Attach a policy for its role, as act-refund does with `rls_all_orders` |
| `DROP RLS POLICY` fails | The policy is still attached to a role | Detach it from every role first (see Clean up) |

### Clean up

> [!WARNING]
> Detach the policies that other READMEs attached to `sales.orders` first, or `DROP RLS POLICY` fails while they're attached: `rls_region_west` from `kb_sales_reader` (knowledge base path), `rls_sales_metrics_regions` from `sales_metrics_tool` (custom MCP server path), `rls_all_orders` from `refund_owner` (act-refund). Their cleanups do this; the root clean-up order runs them first.

Run this block in every database where you ran `fine-grained-access.sql`:

```sql
DETACH MASKING POLICY mask_card_last4 ON sales.payments(card_number) FROM ROLE agent_support;
DROP MASKING POLICY mask_card_last4;
REVOKE SELECT (customer_id, segment, region, signup_date) ON sales.customers FROM ROLE agent_support;
DETACH RLS POLICY rls_region_west ON sales.orders FROM ROLE agent_support;
DROP RLS POLICY rls_region_west;
ALTER TABLE sales.orders ROW LEVEL SECURITY OFF;
```

Check the result:

```sql
SELECT is_rls_on FROM svv_rls_relation WHERE relname = 'orders';
```

Expected: no rows. With row-level security off and no policy attached, `svv_rls_relation` no longer lists `orders`.

### Used by

All five access paths, and [act-refund](../act-refund/README.md), whose procedure owner needs its own policy on `sales.orders`.

## Metadata security

### When to use it

When agents must not learn which tables and schemas exist beyond the ones they can query: with metadata security on, catalog views and `SHOW TABLES` list only objects the user has access to. It addresses excessive agency. It applies to the whole workgroup, so test it on a non-production workgroup first.

### Who runs it

A superuser.

### Prerequisites

- A superuser.
- A monitoring role that must still see every object, `agent_monitoring` in the file. Create it (`CREATE ROLE agent_monitoring;`) or change the name to your monitoring role.

Placeholders: example name `agent_monitoring`.

### How it works

This group is the "Metadata security" box of the diagram above. `ALTER SYSTEM SET metadata_security = true` limits catalog visibility for every user, and `GRANT ACCESS CATALOG` lets one role see the whole catalog again. See [Metadata security](https://docs.aws.amazon.com/redshift/latest/dg/t_metadata_security.html) in the Amazon Redshift Database Developer Guide.

### Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`metadata-security.sql`](metadata-security.sql) | Turns on metadata security and grants `ACCESS CATALOG` to `agent_monitoring` | Set up | run as a superuser |

### Set up

Run [`metadata-security.sql`](metadata-security.sql) as a superuser.

### Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| `SHOW TABLES FROM SCHEMA dev.sales;` | the agent | only the tables the agent can access: `orders`, `payments`, and `customers` through its column grant |
| `SELECT table_schema, table_name FROM svv_tables;` | the agent | only objects the agent can access, plus the system views |
| The same query | a user that holds `agent_monitoring` | every table, including those it has no privileges on, such as `support.tickets` |

### Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| A monitoring or reporting user sees fewer tables than before | Metadata security is on and the user holds no role with `ACCESS CATALOG` | Grant `ACCESS CATALOG` to that user's role |
| `GRANT ACCESS CATALOG` fails | The role `agent_monitoring` doesn't exist | Create it, or use your monitoring role's name |

### Clean up

Leave metadata security on if other workloads rely on it; turning it off makes every catalog object visible again to every user. To undo the file, as a superuser:

```sql
ALTER SYSTEM SET metadata_security = false;
REVOKE ACCESS CATALOG FROM ROLE agent_monitoring;
```

### Used by

All five access paths.

## Lakehouse tables
<!-- documented-only -->

### When to use it

When agents read Apache Iceberg tables, including Amazon S3 Tables, through Redshift, or read Redshift data from another warehouse. Redshift grants don't cover these tables, so the permissions that limit them are set in AWS Lake Formation or in federated permissions. It addresses excessive agency.

### Who runs it

A Lake Formation administrator for the Lake Formation permissions; a Redshift administrator for federated permissions and datashares.

### Where to set it

| Control | Service | Console or API | Documentation |
| --- | --- | --- | --- |
| Lake Formation permissions on Iceberg tables, including S3 Tables, that Redshift queries through the AWS Glue Data Catalog. Set them before the agent's role can query the catalog | AWS Lake Formation | Lake Formation console, or `aws lakeformation grant-permissions` | [Querying catalogs registered in the AWS Glue Data Catalog](https://docs.aws.amazon.com/redshift/latest/dg/iceberg-integration-querying.html); [Query Amazon S3 Tables from Amazon Redshift](https://docs.aws.amazon.com/redshift/latest/dg/querying-s3Tables.html) |
| Federated permissions: define permissions once, including row-level security and dynamic data masking, and have them enforced on every Redshift warehouse in the account | Amazon Redshift with the AWS Glue Data Catalog | Redshift console and SQL | [Amazon Redshift federated permissions](https://docs.aws.amazon.com/redshift/latest/dg/federated-permissions.html); [Managing access control on the federated permissions catalog](https://docs.aws.amazon.com/redshift/latest/dg/federated-permissions-managing-access.html) |
| Datashares and row-level security: a consumer query on a table with row-level security fails unless RLS is turned off for datashares, which shares every row. Share such tables through Lake Formation-managed datashares, where Lake Formation sets the row and column permissions | Amazon Redshift; AWS Lake Formation | `ALTER TABLE ... ROW LEVEL SECURITY OFF FOR DATASHARES`; Lake Formation console | [Considerations and limitations using RLS policies](https://docs.aws.amazon.com/redshift/latest/dg/t_rls_usage.html); [AWS Lake Formation-managed datashares](https://docs.aws.amazon.com/redshift/latest/dg/lf_datashare_overview.html) |

### Used by

All five access paths, when the agent's queries reach Iceberg tables or shared data.

## Exports and copies

### When to use it

To control what an agent can take out of Redshift or copy inside it. Row-level security and masking end when a result leaves the database, so limit who can UNLOAD to Amazon S3 and who can create tables. It addresses excessive agency.

![Grid of output guardrails by layer for what the agent sees, keeps, and says. Agent layer: optional ApplyGuardrail screening of retrieved text, retained results governed by your application, and Bedrock Guardrails checks on the answer with the SQL kept. Access layer: the MCP Server MAX_RESULT_ROWS cap, and read-only mode that denies UNLOAD and CALL, with one approved write tool and approval above a threshold. Data layer: row-level security, column privileges, masking, and Lake Formation filters, plus ASSUMEROLE scoped for UNLOAD, s3:PutObject only to approved buckets, and no write or datashare privileges for agent roles. Data layer controls end when the result leaves Redshift.](../images/fig5-output-guardrails.png)

| Export or copy path | Guardrail | Where it's set |
| --- | --- | --- |
| UNLOAD to Amazon S3 | `ASSUMEROLE ... FOR UNLOAD` only for pipeline roles; the IAM role's `s3:PutObject` only on approved buckets | `exports-and-copies.sql`; the IAM role's policy |
| CREATE EXTERNAL TABLE AS (CETAS) and external tables | No `CREATE` on external schemas for agent roles | Grants on the external schema |
| Writes to Iceberg tables | No write permissions in Lake Formation for agent roles | AWS Lake Formation |
| CREATE TABLE AS (CTAS) and SELECT INTO | No `CREATE` on `public` for `PUBLIC`, and no `CREATE` on other schemas for agent roles | `exports-and-copies.sql`; schema grants |
| Datashares | No datashare privileges for agent roles | Grants |

### Who runs it

A superuser.

### Prerequisites

- A superuser.
- A pipeline database role that may UNLOAD (`etl_pipeline` in the file) and an IAM role for UNLOAD associated with the workgroup's namespace (`etl-unload` in the file). Both are example names; use your own.
- If you use Redshift ML or COPY, the IAM role ARNs that each needs, for the grant-back lines in the warning below.

Placeholders: `111122223333` (the example account ID in the role ARN), example names `etl-unload` and `etl_pipeline`; in the grant-back line, `<redshift-ml-role-arn>` (the model's IAM role) and `<tool-role>` (the database role that calls the model, for example `support_summary_tool`).

### How it works

This group is the "Exports and copies" branch of the diagram above. After `REVOKE ASSUMEROLE ON ALL FROM PUBLIC FOR ALL`, a user can use an IAM role for UNLOAD only if a role it holds was granted `ASSUMEROLE` on that IAM role for UNLOAD. `REVOKE CREATE ON SCHEMA public FROM PUBLIC` stops users from creating tables in `public` unless they're granted `CREATE` there. To audit exports and the bucket writes they make, see [observe/export-audit](../observe/export-audit/README.md).

### Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`exports-and-copies.sql`](exports-and-copies.sql) | Revokes `ASSUMEROLE` from `PUBLIC` for all uses, grants it back to `etl_pipeline` for UNLOAD on one IAM role, and revokes `CREATE` on schema `public` from `PUBLIC` | Set up step 1 | run as a superuser |

### Set up

#### 0. Record the current settings

Record what the workgroup has before you change it, so cleanup can restore it. As a superuser:

```sql
SELECT * FROM svv_iam_privileges;
```

Then, as a regular user (not a superuser):

```sql
SELECT has_schema_privilege('public', 'CREATE');
```

What this does:
- Lists the `ASSUMEROLE` grants that exist now. The default `ASSUMEROLE` of `PUBLIC` isn't a row in this view, so on a workgroup where nobody has run `REVOKE ASSUMEROLE`, it returns no rows.
- Shows whether regular users can create tables in `public` now (`true` by default).

#### 1. Limit UNLOAD and CREATE

> [!WARNING]
> `REVOKE ASSUMEROLE ON ALL FROM PUBLIC FOR ALL` also stops COPY, CREATE MODEL and Redshift ML inference for every user until you grant each IAM role back for that use. Redshift ML inference needs `GRANT ASSUMEROLE ON '<redshift-ml-role-arn>' TO ROLE <tool-role> FOR EXTERNAL FUNCTION`, as in [`../cost-envelope/model-spend-summarizer.sql`](../cost-envelope/model-spend-summarizer.sql) and [`../cost-envelope/precompute-prompts.sql`](../cost-envelope/precompute-prompts.sql).

Run [`exports-and-copies.sql`](exports-and-copies.sql) as a superuser.

What this does:
- Only `etl_pipeline` can use the `etl-unload` IAM role, and only for UNLOAD.
- Nobody creates tables in `public` without an explicit `CREATE` grant.

### Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| An `UNLOAD` with `IAM_ROLE 'arn:aws:iam::111122223333:role/etl-unload'` | a user without `etl_pipeline`, such as the agent | `User ... does not have ASSUMEROLE permission on IAM role "..." for UNLOAD` |
| The same `UNLOAD` | a user that holds `etl_pipeline` | the files are written |
| `SELECT has_schema_privilege('public', 'CREATE');` | a regular user | `false` |

### Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| `does not have ASSUMEROLE permission ... for EXTERNAL FUNCTION` on a Redshift ML call | `REVOKE ASSUMEROLE ... FOR ALL` also removed inference | Grant the model's IAM role back `FOR EXTERNAL FUNCTION` to the tool's role (see the warning in step 1) |
| COPY or CREATE MODEL fails with a missing `ASSUMEROLE` permission | The same revoke | Grant the IAM role back to the role that runs it, `FOR COPY` or `FOR CREATE MODEL` |
| `permission denied for schema public` on `CREATE TABLE` | Expected after the revoke | Grant `CREATE` on a schema meant for that user's tables |

### Clean up

Restore what you recorded before setup, not the defaults, if your workgroup had its own settings. As a superuser:

```sql
REVOKE ASSUMEROLE ON 'arn:aws:iam::111122223333:role/etl-unload' FROM ROLE etl_pipeline FOR UNLOAD;
-- Only if PUBLIC held these before setup (the Redshift defaults):
GRANT ASSUMEROLE ON ALL TO PUBLIC FOR ALL;
GRANT CREATE ON SCHEMA public TO PUBLIC;
```

### Used by

All five access paths and [act-refund](../act-refund/README.md).
