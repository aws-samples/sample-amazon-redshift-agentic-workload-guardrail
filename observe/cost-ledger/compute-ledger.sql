-- Purpose: a daily compute ledger per agent database user and query label: queries, execution seconds, each
--   one's share of the workgroup's execution time, and that share of the RPU-hours the workgroup was charged.
--   Redshift Serverless charges the workgroup, not individual queries, so est_rpu_hours is an estimate (on a
--   dedicated agent workgroup, use the workgroup total from SYS_SERVERLESS_USAGE or the workgroup's tags instead).
-- Post section: "Attribute compute and inference costs" (per-agent database users make SYS_QUERY_HISTORY a ledger).
-- Prerequisites: run as a superuser or a user with the sys:monitor role (a regular user sees only its own queries).
-- Placeholders: 'IAMR:agent-%' (your agent naming convention), the 7-day window.
WITH q AS (
  SELECT TRUNC(h.start_time) AS day, TRIM(u.usename) AS db_user,
         NVL(NULLIF(TRIM(h.query_label), ''), 'default') AS query_label, h.execution_time
  FROM sys_query_history h
  JOIN pg_user u ON u.usesysid = h.user_id
  WHERE h.start_time >= DATEADD(day, -7, GETDATE())
    AND h.query_type <> 'UTILITY'
    AND h.query_text NOT LIKE 'SELECT pg_last_query_id()%'   -- Data API bookkeeping
    AND TRIM(h.query_text) <> ''                             -- Data API session keep-alive pings
),
day_total AS (SELECT day, SUM(execution_time) AS exec_us FROM q GROUP BY day),
charged AS (SELECT TRUNC(start_time) AS day, SUM(charged_seconds) / 3600.0 AS rpu_hours
            FROM sys_serverless_usage
            WHERE start_time >= DATEADD(day, -7, GETDATE())
            GROUP BY 1)
SELECT q.day, q.db_user AS agent_user, q.query_label, COUNT(*) AS queries,
       ROUND(SUM(q.execution_time) / 1000000.0, 3) AS exec_seconds,
       ROUND(100.0 * SUM(q.execution_time) / NULLIF(MAX(t.exec_us), 0), 2) AS pct_of_workgroup,
       ROUND(MAX(c.rpu_hours) * SUM(q.execution_time) / NULLIF(MAX(t.exec_us), 0), 4) AS est_rpu_hours
FROM q
JOIN day_total t ON t.day = q.day
LEFT JOIN charged c ON c.day = q.day
WHERE q.db_user LIKE 'IAMR:agent-%'
GROUP BY 1, 2, 3
ORDER BY 1 DESC, exec_seconds DESC;
