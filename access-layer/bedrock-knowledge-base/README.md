# Bedrock Knowledge Bases: one identity for every end user

On this path end users ask questions in natural language, and Amazon Bedrock Knowledge Bases turns each question into SQL and runs it on Redshift through the Data API as the knowledge base's service role. It addresses excessive agency (one database, listed tables, excluded columns, a database role with `SELECT` on the included tables only) and unbounded consumption (a query timeout and a connection limit).
In the accompanying blog post: section "Data plane: a narrow tool surface on every path".

## When to use this path

Use it for managed natural-language query for end users, where an application calls `Retrieve` or `RetrieveAndGenerate` and the knowledge base generates the SQL. One identity serves every end user of a knowledge base, so create one knowledge base per audience (for example, one for the west region's users). It's normally set up by an application or data team, with an IAM administrator for the service role and a database administrator for the database user and grants.

Use another path if each agent needs its own identity and fixed SQL (the `custom-mcp-server` or `agentcore-custom-agent` path). See [Choose your path](../README.md#choose-your-path).

## How the agent reaches Redshift

The application sends a question with `Retrieve` or `RetrieveAndGenerate`. Bedrock Knowledge Bases generates SQL for it (the same step that the `GenerateQuery` API exposes), using the metadata that ingestion read from the database and the tables listed in [`kb-redshift-config.json`](kb-redshift-config.json). It runs the SQL through the Redshift Data API on one workgroup, signed in with `redshift-serverless:GetCredentials` as the service role, and returns the rows.

## Which identity Redshift sees

Redshift sees the service role as one database user, `IAMR:<kb-role>`, for every end user. This path uses IAM authentication; the other two methods are a database user name (provisioned clusters only) and an AWS Secrets Manager secret ([Set up your query engine and permissions](https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-prereq-structured.html)). Because every end user shares the database user, row-level security filters for the whole audience, not for each person.

Least privilege needs both scopes: the IAM policy limits the service role to one workgroup and its own statements, and the database permissions of `kb_sales_reader` allow `SELECT` on the included tables only.

## Workflow

![Workflow for Amazon Bedrock Knowledge Bases. An application sends end users' questions to a knowledge base, which generates SQL and runs it through the Data API as its service role. Redshift sees one database user, IAMR followed by the role name, for every end user, with the kb_sales_reader database role. Guardrails: one knowledge base per audience, one database with listed tables and a 60-second timeout, a service role scoped to one workgroup and its own statements, select grants on the included tables only, and a row-level security policy for the audience.](../../images/access-path-bedrock-knowledge-base.png)

1. Client: an application where end users ask questions with `Retrieve`; one knowledge base per audience.
2. Service: Amazon Bedrock Knowledge Bases turns each question into SQL, with one database, the included tables and a 60-second timeout.
3. IAM role and policy: the knowledge base service role with `kb-service-role-policy.json`: one workgroup, its own statements, and `CancelStatement` for sync.
4. Sign-in and database user: `IAMR:<kb-role>`, one database user for every end user, so row-level security can't tell end users apart.
5. Database role and permissions: `kb_sales_reader`, with `SELECT` on the included tables and row-level security for the audience; no `sys:monitor` and no superuser.
6. Data: Redshift managed storage; excluded columns never reach the generated SQL.

## Guardrails on this path

| Layer | Guardrail | Where it's set | File or setting |
| --- | --- | --- | --- |
| Agent layer | One knowledge base per audience, because one database user serves all its end users | Bedrock Knowledge Bases | One `create-knowledge-base` per audience (step 7) |
| Access layer | One database, the listed tables, excluded columns | Knowledge base configuration | `databaseName`, `generationContext.tables` and `"inclusion": "EXCLUDE"` in `kb-redshift-config.json`; up to 50 tables ([QueryGenerationContext](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_QueryGenerationContext.html)) |
| Access layer | 60-second query timeout | Knowledge base configuration | `executionTimeoutSeconds` in `kb-redshift-config.json`; 1 to 200 seconds ([QueryGenerationConfiguration](https://docs.aws.amazon.com/bedrock/latest/APIReference/API_agent_QueryGenerationConfiguration.html)) |
| Access layer | SQL on one workgroup; status, results and `CancelStatement` on the role's own statements only | IAM | `kb-service-role-policy.json` |
| Data layer | `SELECT` on the included tables only, through one database role | Redshift | Step 4 |
| Data layer | Row-level security for the audience | Redshift | Step 5 |
| Data layer | No `sys:monitor` and no superuser for the knowledge base user | Redshift | Don't grant them. In SYS_QUERY_HISTORY a regular user sees only its own queries, and a superuser sees every user's ([SYS_QUERY_HISTORY](https://docs.aws.amazon.com/redshift/latest/dg/SYS_QUERY_HISTORY.html)) |
| Cost envelope | `CONNECTION LIMIT` on the knowledge base user | Redshift | Step 6 |

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`kb-redshift-config.json`](kb-redshift-config.json) | The `redshiftConfiguration` object for `create-knowledge-base`: a Redshift Serverless query engine with IAM authentication on one workgroup, the database `sales_dw`, a 60-second `executionTimeoutSeconds`, and a generation context with `sales_dw.sales.orders` and `sales_dw.sales.customers` included and the `email` column excluded | `aws bedrock-agent create-knowledge-base`, wrapped with `jq` (step 7) | none (configuration read by the knowledge base) |
| [`kb-service-role-policy.json`](kb-service-role-policy.json) | IAM policy for the service role: `ExecuteStatement` and `GetCredentials` on one workgroup; `DescribeStatement`, `GetStatementResult` and `CancelStatement` on the role's own statements only; the SQL generation context actions and `bedrock:GenerateQuery` | Inline policy `kb-service` on the service role (step 2) | attached to the service role |

## Prerequisites

- An Amazon Redshift Serverless workgroup, with a database `sales_dw` that holds `sales.orders` and `sales.customers`: the database and tables that `kb-redshift-config.json` names. Users and roles are workgroup-wide, but grants and row-level security policies belong to one database, so the SQL on this page runs in `sales_dw`.
- For `RetrieveAndGenerate`, access to the Amazon Bedrock model that writes the answer. Step 8 uses `Retrieve`, which returns rows without a model answer.
- An IAM administrator for steps 1 and 2, and a database administrator (superuser, or a user with `sys:secadmin` for the row-level security statements) for steps 3 to 6.
- `jq` and AWS CLI v2.
- Name the service role with the `agent-` prefix, for example `agent-kb-sales`, so `IAMR:agent-kb-sales` matches the observe queries' `'IAMR:agent-%'` pattern. With another name, `shadow-agents.sql` reports the knowledge base as an unregistered agent and `compute-ledger.sql` leaves it out; change the pattern in those files if you keep your own name.

Database identity on this path:

| IAM role | Database user | Database role | Where the grants come from | Row-level security and masking |
| --- | --- | --- | --- | --- |
| `<kb-role>`, the service role (for example `agent-kb-sales`) | `IAMR:<kb-role>`, created by the administrator in step 3 | `kb_sales_reader` | Step 4, in database `sales_dw`: the role, `USAGE` on `sales`, `SELECT` on the included tables, and `GRANT ROLE` to the user | Step 5, in `sales_dw`: variant 5A attaches `rls_region_west` if `fine-grained-access.sql` already ran in `sales_dw`; variant 5B creates and attaches `rls_kb_west` if it didn't |

Placeholders in this path:
- `<kb-role>`: the service role's name, for example `agent-kb-sales`.
- `<kb-name>`: the knowledge base's name.
- `<kb-id>`, `<ds-id>` and `<job-id>`: the IDs that `create-knowledge-base`, `create-data-source` and `start-ingestion-job` return.
- `<ds-name>`: the data source's name.
- `<workgroup-id>`: the workgroup's ID, in both JSON files.
- `111122223333` and `us-east-1`: the example account ID and Region, in both JSON files and the trust policy. Replace them with yours.

## Set up

Run each block from the repository root; each one starts with the `cd` it needs.

### 1. Create the IAM role

The service role trusts Amazon Bedrock, limited to knowledge bases in your account ([Create a service role for Amazon Bedrock Knowledge Bases](https://docs.aws.amazon.com/bedrock/latest/userguide/kb-permissions.html)):

```bash
cd access-layer/bedrock-knowledge-base
cat > kb-service-role-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "bedrock.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "111122223333" },
        "ArnLike": { "aws:SourceArn": "arn:aws:bedrock:us-east-1:111122223333:knowledge-base/*" } } }
  ]
}
EOF
aws accessanalyzer validate-policy --policy-type RESOURCE_POLICY \
  --validate-policy-resource-type AWS::IAM::AssumeRolePolicyDocument \
  --policy-document file://kb-service-role-trust.json --query "findings[?findingType=='ERROR']"
aws iam create-role --role-name <kb-role> --assume-role-policy-document file://kb-service-role-trust.json
```

What this does:
- Writes the generated trust file `kb-service-role-trust.json` in this folder (don't commit it), checks it (`[]` means no errors) and creates the service role. After you create the knowledge base, you can replace `knowledge-base/*` with its ID.

### 2. Attach the policy

Replace `111122223333`, `us-east-1` and `<workgroup-id>` in `kb-service-role-policy.json` first.

> [!WARNING]
> Attach the policy with `file://`. Pasting the JSON into a shell can rewrite `${aws:userid}`, and ingestion then fails on `DescribeStatement`.

```bash
cd access-layer/bedrock-knowledge-base
aws iam put-role-policy --role-name <kb-role> --policy-name kb-service \
  --policy-document file://kb-service-role-policy.json
aws iam get-role-policy --role-name <kb-role> --policy-name kb-service
```

What this does:
- Adds the inline policy `kb-service`; `get-role-policy` shows the stored document, whose condition value must read `${aws:userid}`.
- Wait a minute or two after an IAM change before you start an ingestion job.

Run the SQL in steps 3 to 6 connected to the database named in `kb-redshift-config.json` (`sales_dw`).

### 3. Create the database user

As a database administrator in `sales_dw`:

```sql
CREATE USER "IAMR:<kb-role>" PASSWORD DISABLE;
```

What this does:
- Creates the database user that the service role maps to at sign-in, before the first sync, so you can grant it a role first.

### 4. Grant database permissions

```sql
CREATE ROLE kb_sales_reader;
GRANT USAGE ON SCHEMA sales TO ROLE kb_sales_reader;
GRANT SELECT ON sales.orders, sales.customers TO ROLE kb_sales_reader;  -- the included tables only
GRANT ROLE kb_sales_reader TO "IAMR:<kb-role>";
```

What this does:
- Creates `kb_sales_reader` with `USAGE` on `sales` and `SELECT` on the two included tables only, with no `CREATE`, `UPDATE` or `DELETE`, and grants it to the knowledge base user.

### 5. Add row-level security and masking

One database user serves every end user, so row-level security can't tell end users apart; it filters for the whole audience. Both variants below are for a knowledge base that serves the west region's users.

> [!WARNING]
> If row-level security is on for `sales.orders` in `sales_dw`, the knowledge base returns no `sales.orders` rows until you attach a policy to its role.

#### 5A. If you ran fine-grained-access.sql in sales_dw

```sql
ATTACH RLS POLICY rls_region_west ON sales.orders TO ROLE kb_sales_reader;
```

#### 5B. If you didn't

For example, you ran [`fine-grained-access.sql`](../../data-layer/fine-grained-access.sql) only in `dev`, where the data-layer README runs it. Row-level security policies belong to one database, so `rls_region_west` from `dev` isn't visible in `sales_dw`. Create an audience policy in `sales_dw`:

> [!WARNING]
> Turning row-level security on makes `sales.orders` in `sales_dw` default-deny for every other role that reads it; attach a policy for those roles first.

```sql
CREATE RLS POLICY rls_kb_west WITH (region VARCHAR(16)) USING (region = 'west');
ATTACH RLS POLICY rls_kb_west ON sales.orders TO ROLE kb_sales_reader;
ALTER TABLE sales.orders ROW LEVEL SECURITY ON;
```

Masking: the excluded `email` column in `kb-redshift-config.json` keeps it out of generated SQL. `mask_card_last4` doesn't apply, because `sales.payments` isn't an included table.

What this does:
- Limits the knowledge base to `region = 'west'` rows of `sales.orders`, with the data-layer policy (5A) or its own policy (5B).

### 6. Set per-user limits

As a database administrator in `sales_dw`. Size the limit to the audience's concurrency.

```sql
ALTER USER "IAMR:<kb-role>" CONNECTION LIMIT 10;
```

Superusers ignore connection limits.

What this does:
- Allows at most 10 concurrent connections for the knowledge base user. No `statement_timeout` is set here: `executionTimeoutSeconds` (60) in `kb-redshift-config.json` already caps each query.

### 7. Configure the knowledge base

Replace `<workgroup-id>`, `111122223333` and `us-east-1` in `kb-redshift-config.json` first. Then wrap it into the `create-knowledge-base` input, create the knowledge base, add the Redshift metadata data source and run ingestion:

```bash
cd access-layer/bedrock-knowledge-base
jq --arg role "arn:aws:iam::111122223333:role/<kb-role>" \
  '{name: "<kb-name>", roleArn: $role, knowledgeBaseConfiguration: {type: "SQL", sqlKnowledgeBaseConfiguration: {type: "REDSHIFT", redshiftConfiguration: .}}}' \
  kb-redshift-config.json > kb-create-input.json
aws bedrock-agent create-knowledge-base --cli-input-json file://kb-create-input.json --region us-east-1 \
  --query "knowledgeBase.[knowledgeBaseId,status]"
aws bedrock-agent get-knowledge-base --knowledge-base-id <kb-id> --region us-east-1 --query knowledgeBase.status
aws bedrock-agent create-data-source --knowledge-base-id <kb-id> --name <ds-name> \
  --data-source-configuration type=REDSHIFT_METADATA --region us-east-1 --query dataSource.dataSourceId
aws bedrock-agent start-ingestion-job --knowledge-base-id <kb-id> --data-source-id <ds-id> --region us-east-1 \
  --query ingestionJob.ingestionJobId
aws bedrock-agent get-ingestion-job --knowledge-base-id <kb-id> --data-source-id <ds-id> \
  --ingestion-job-id <job-id> --region us-east-1 --query ingestionJob.status
```

What this does:
- Writes the generated file `kb-create-input.json` (don't commit it) and creates the knowledge base; run `get-knowledge-base` until it shows `"ACTIVE"`.
- Creates the data source and starts ingestion, which reads the database metadata; run `get-ingestion-job` until it shows `"COMPLETE"`. Run ingestion again after you change the schema. See [Create a knowledge base by connecting to a structured data store](https://docs.aws.amazon.com/bedrock/latest/userguide/knowledge-base-structured-create.html).

### 8. Try it

```bash
aws bedrock-agent-runtime generate-query --region us-east-1 \
  --query-generation-input '{"type": "TEXT", "text": "Total order amount by region last month"}' \
  --transformation-configuration '{"mode": "TEXT_TO_SQL", "textToSqlConfiguration": {"type": "KNOWLEDGE_BASE", "knowledgeBaseConfiguration": {"knowledgeBaseArn": "arn:aws:bedrock:us-east-1:111122223333:knowledge-base/<kb-id>"}}}'
aws bedrock-agent-runtime retrieve --knowledge-base-id <kb-id> --region us-east-1 \
  --retrieval-query '{"text": "Total order amount by region last month"}'
```

What this does:
- `generate-query` returns the SQL the knowledge base generates, without running it.
- `retrieve` runs the SQL as `IAMR:<kb-role>` and returns the rows.

## Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| `get-ingestion-job` (step 7) | IAM principal that created the knowledge base | `COMPLETE` |
| `generate-query` (step 8) | application identity | an SQL statement on `sales.orders` or `sales.customers` |
| `retrieve` (step 8) | application identity | rows; with step 5 applied (5A or 5B), only `west` rows from `sales.orders` |
| `generate-query` with a question about customers' `email`, for example "List customer email addresses" | application identity | `SQLGenerationException`; the column is excluded. `retrieve` with the same question fails with an HTTP 400 error and an empty message |
| SYS_QUERY_HISTORY in `sales_dw` | database administrator | every statement runs under `IAMR:<kb-role>`, whoever asked the question |
| `SELECT usename, useconnlimit FROM pg_user_info WHERE usename = 'IAMR:<kb-role>';` | database administrator | `useconnlimit` is `10` |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| Ingestion fails with `not authorized to perform: redshift-data:CancelStatement` | The service role can't cancel its own statements; ingestion calls `CancelStatement` | Attach `kb-service-role-policy.json` again (step 2); it allows `CancelStatement` on the role's own statements |
| AccessDenied on `DescribeStatement` after attaching the policy | The shell rewrote `${aws:userid}` | Attach the file with `file://` and check it with `get-role-policy` |
| Ingestion fails right after an IAM change | IAM changes take a short time to propagate | Retry after a minute or two |
| `SQLGenerationException` from `generate-query`, or an HTTP 400 error with an empty message from `retrieve`, for a question about an excluded column | By design: the column is excluded from generated SQL | Nothing to fix |
| `retrieve` returns no order rows | Row-level security is on for `sales.orders` in `sales_dw` and no policy is attached to `kb_sales_reader` | Run step 5 |
| `permission denied for relation orders` | The role wasn't granted to `IAMR:<kb-role>`, or the grants ran in `dev` instead of `sales_dw` | Run step 4 connected to `sales_dw` |
| `ERROR: rls policy "rls_region_west" does not exist` from `ATTACH RLS POLICY` in step 5A | The session is connected to `sales_dw`, but `fine-grained-access.sql` ran only in `dev`; row-level security policies belong to one database | Use variant 5B |
| `shadow-agents.sql` shows the knowledge base user with `registered_agent` false | The service role name has no `agent-` prefix | Use an `agent-` name, or change the pattern (see Prerequisites) |

## Clean up

1. Delete the data source and the knowledge base:

   ```bash
   aws bedrock-agent delete-data-source --knowledge-base-id <kb-id> --data-source-id <ds-id> --region us-east-1
   aws bedrock-agent delete-knowledge-base --knowledge-base-id <kb-id> --region us-east-1
   ```

2. As a database administrator connected to `sales_dw`, remove the row-level security of the variant you used. For 5A:

   ```sql
   DETACH RLS POLICY rls_region_west ON sales.orders FROM ROLE kb_sales_reader;
   ```

   For 5B (turn row-level security off only if no other role relies on it on that table in `sales_dw`):

   ```sql
   ALTER TABLE sales.orders ROW LEVEL SECURITY OFF;
   DETACH RLS POLICY rls_kb_west ON sales.orders FROM ROLE kb_sales_reader;
   DROP RLS POLICY rls_kb_west;
   ```

3. Then drop the role and the user, still in `sales_dw`:

   ```sql
   REVOKE ROLE kb_sales_reader FROM "IAMR:<kb-role>";
   REVOKE SELECT ON sales.orders, sales.customers FROM ROLE kb_sales_reader;
   REVOKE USAGE ON SCHEMA sales FROM ROLE kb_sales_reader;
   DROP ROLE kb_sales_reader;
   DROP USER "IAMR:<kb-role>";
   ```

4. Delete the IAM role. Its inline policy is `kb-service`; `delete-role` fails with `DeleteConflict` while it remains.

   ```bash
   aws iam list-role-policies --role-name <kb-role>
   aws iam delete-role-policy --role-name <kb-role> --policy-name kb-service
   aws iam list-attached-role-policies --role-name <kb-role>
   aws iam delete-role --role-name <kb-role>
   ```

   `list-attached-role-policies` is expected to return an empty list.
5. Delete the generated files:

   ```bash
   cd access-layer/bedrock-knowledge-base
   rm kb-service-role-trust.json kb-create-input.json
   ```

6. Then run the data-layer cleanup if no other path still uses `agent_support` or row-level security on `sales.orders`.

## Related

- [Shared controls](../shared/): the organization-wide controls. This path doesn't need them for setup: it uses its own `kb-service-role-policy.json`, and the shared deny statements don't act on Knowledge Bases requests.
- [Data layer](../../data-layer/): fine-grained access, the source of `rls_region_west`.
- More limits: [cost-envelope](../../cost-envelope/)
- [Observe: detection](../../observe/detection/) and [cost ledger](../../observe/cost-ledger/): shadow agents and compute per agent, which match `'IAMR:agent-%'`.
- The other paths: [Redshift MCP Server](../redshift-mcp-server/), [AWS MCP Server](../aws-mcp-server/), [custom MCP server](../custom-mcp-server/), [AgentCore custom agent](../agentcore-custom-agent/).
