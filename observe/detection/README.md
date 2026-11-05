# Detection: shadow agents, runaway loops, idle sessions and reach

Four queries over Redshift system views that find what the guardrails alone don't show: agents that run without their own identity, agents that repeat the same query or error in a loop, sessions that hold connections open while idle, and every table privilege each agent user holds.
In the accompanying blog post: sections "Data layer: decide what the agent can reach" (audit each agent's reach, find shadow agents) and "Observe and prove".

## When to use it

On a schedule after agents go live. Shadow agents and reach address excessive agency: an agent that runs as a developer's own role, or holds more privileges than you meant, isn't bounded by its own guardrails. Runaway loops and idle sessions address unbounded consumption, and help you size `CONNECTION LIMIT` and `SESSION TIMEOUT` for each agent user.

## Who runs it

- The monitoring role with `sys:monitor`, for `shadow-agents.sql`, `runaway-loops.sql` and `idle-sessions.sql`.
- A superuser, for `agent-table-privileges.sql`, because it must see every table even with metadata security on.

## Prerequisites

- `sys:monitor` for the monitoring user ([observe Prerequisites](../README.md#prerequisites)).
- A superuser for `agent-table-privileges.sql`.
- A scheduler for `runaway-loops.sql`, for example a query editor v2 scheduled query. See [Scheduled queries with query editor v2](https://docs.aws.amazon.com/redshift/latest/mgmt/query-editor-v2-schedule-query.html).

Placeholders:
- `'IAMR:agent-%'`: the agent naming convention in every file. Change it if your agents are named differently.
- The thresholds in each file: 20 hits of one query shape or 5 repeated errors in 15 minutes (`runaway-loops.sql`), `<idle-minutes>` (`idle-sessions.sql`), the 7-day window (`shadow-agents.sql`).

## How it works

This group is the DETECTION box of the [observe workflow](../../images/observe-workflow.png); it reads system views only.

- `shadow-agents.sql` counts Data API and Redshift MCP Server sessions per database user over the last 7 days, from the `SET application_name` statements each client sends, and flags users outside the `agent-` naming convention as `registered_agent` false.
- `runaway-loops.sql` is a heuristic: it flags an agent user that ran one query shape (`generic_query_hash`) 20 or more times, or hit the same error 5 or more times, in the last 15 minutes.
- `idle-sessions.sql` lists open sessions idle for at least `<idle-minutes>`, per database user.
- `agent-table-privileges.sql` lists every table privilege each agent user holds, however it was granted: directly, through roles, or to `PUBLIC`.

## Files

| File | What it is | Where you use it | Identity |
| --- | --- | --- | --- |
| [`shadow-agents.sql`](shadow-agents.sql) | Data API and Redshift MCP Server sessions per database user over the last 7 days, with `registered_agent` false for users outside the `agent-` convention | Set up step 1 | runs as the monitoring role with `sys:monitor` |
| [`runaway-loops.sql`](runaway-loops.sql) | Repeated query shapes or errors per agent user in the last 15 minutes | Set up step 2, on a schedule | runs as the monitoring role with `sys:monitor` |
| [`idle-sessions.sql`](idle-sessions.sql) | Open sessions idle for at least `<idle-minutes>`, per database user | Set up step 3 | runs as the monitoring role with `sys:monitor` |
| [`agent-table-privileges.sql`](agent-table-privileges.sql) | Every table privilege each agent user holds, from `HAS_TABLE_PRIVILEGE` | Set up step 4 | run as a superuser |

## Set up

Run each file in database `dev`, in query editor v2 or through the Data API.

### 1. Find shadow agents

Run [`shadow-agents.sql`](shadow-agents.sql) as the [monitoring role](../README.md#prerequisites). Sample output (illustrative values):

```text
db_user                      | client              | sessions | last_seen             | registered_agent
IAMR:<developer-role>        | Redshift MCP Server | <n>      | <yyyy-mm-dd hh:mm:ss> | false
IAMR:agent-redshift-readonly | Redshift MCP Server | <n>      | <yyyy-mm-dd hh:mm:ss> | true
```

Give each user flagged `false` its own agent identity on one of the access paths, or block it.

### 2. Check for runaway loops on a schedule

Run [`runaway-loops.sql`](runaway-loops.sql) as the [monitoring role](../README.md#prerequisites) every 15 minutes, for example as a query editor v2 scheduled query. To alarm on it, publish the row count as a custom CloudWatch metric, as [`../remaining-configuration.md`](../remaining-configuration.md) describes. Sample output (illustrative values):

```text
agent_user         | signal           | signature      | hits
IAMR:agent-support | same query shape | <query-hash>   | <n>
IAMR:agent-support | repeated error   | <error-shape>  | <n>
```

### 3. List idle sessions

Replace `<idle-minutes>` in [`idle-sessions.sql`](idle-sessions.sql), for example with `30`, and run it as the [monitoring role](../README.md#prerequisites). Sample output (illustrative values):

```text
db_user            | session_id | database_name | session_start         | session_timeout | last_query_end        | idle_minutes
IAMR:agent-support | <id>       | dev           | <yyyy-mm-dd hh:mm:ss> | <seconds>       | <yyyy-mm-dd hh:mm:ss> | <n>
```

### 4. Audit each agent's reach

Run [`agent-table-privileges.sql`](agent-table-privileges.sql) as a superuser. Sample output (illustrative values):

```text
agent_user         | relation     | priv
IAMR:agent-support | sales.orders | SELECT
```

## Verify

| Check | Run as | Expected result |
| --- | --- | --- |
| `shadow-agents.sql` | monitoring role | every database user that used the Data API or the Redshift MCP Server; users outside the `agent-` convention have `registered_agent` false |
| `runaway-loops.sql` | monitoring role | no rows while agents behave; a row per agent user with one query shape at 20 or more hits, or one error at 5 or more, in the last 15 minutes |
| `idle-sessions.sql` | monitoring role | the open sessions idle for at least the threshold |
| `agent-table-privileges.sql` | superuser | one row per agent user, table and privilege, for example `SELECT` on `sales.orders` and `sales.payments` for `IAMR:agent-support` after the data-layer setup |

## Common errors

| Error or symptom | Cause | Fix |
| --- | --- | --- |
| A query returns only the monitoring user's own rows | The monitoring user doesn't hold `sys:monitor` | Grant it ([observe Prerequisites](../README.md#prerequisites)) |
| `agent-table-privileges.sql` shows no privileges for an agent that can read tables | Its privileges come from a session role mapped by the `RedshiftDbRoles` tag, or from column-level grants; `HAS_TABLE_PRIVILEGE` sees neither | Audit the tag and `SHOW GRANTS FOR ROLE <role>` (see [data-layer Database identity and roles](../../data-layer/README.md#database-identity-and-roles)), and audit column grants separately |
| A Data API session never shows as idle | A session held open with `SessionKeepAliveSeconds` gets keep-alive queries from the Data API | Find those sessions with the Data API `ListSessions` operation |
| Idle times look shorter than expected | On Redshift Serverless a session's start time can move forward, so idle time is a lower bound | Use the result to size limits, not as an exact duration |

## Clean up

These are queries only; there's nothing to undo. Delete any schedule you created for `runaway-loops.sql`.

## Used by

All five access paths: their optional Verify rows run `shadow-agents.sql`, and the per-user limits in their step 6 are what `idle-sessions.sql` helps you size.
