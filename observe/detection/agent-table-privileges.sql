-- Every table privilege each agent-path user holds, however it was granted: directly, through roles, or to PUBLIC
-- Run as a superuser, which sees every table even with metadata security on
-- Column-level grants (GRANT SELECT (col, ...)) aren't listed: HAS_TABLE_PRIVILEGE checks the whole table, so a
-- role with SELECT on only some columns of a table has no row here. Audit column grants separately.
SELECT u.usename AS agent_user, t.table_schema || '.' || t.table_name AS relation, p.priv
FROM pg_user u
CROSS JOIN svv_tables t
CROSS JOIN (SELECT 'SELECT' AS priv UNION ALL SELECT 'INSERT' UNION ALL SELECT 'UPDATE'
            UNION ALL SELECT 'DELETE' UNION ALL SELECT 'DROP' UNION ALL SELECT 'REFERENCES') p
WHERE u.usename LIKE 'IAMR:agent-%'
  AND t.table_catalog = current_database()
  AND t.table_type IN ('BASE TABLE', 'VIEW')
  AND LEFT(t.table_schema, 3) <> 'pg_' AND t.table_schema <> 'information_schema'
  AND HAS_TABLE_PRIVILEGE(u.usename, t.table_schema || '.' || t.table_name, p.priv)
ORDER BY 1, 2, 3;
