WITH a AS (SELECT session_id, TRIM(user_name) AS db_user, TRIM(application_name) AS app, record_time AS t0,
             LEAD(record_time) OVER (PARTITION BY session_id ORDER BY record_time) AS t1
           FROM sys_connection_log WHERE event IN ('set application_name', 'disconnecting session'))
SELECT a.db_user, REGEXP_REPLACE(a.app, '[0-9a-f-]{36}', '<statement-id>') AS app, TRIM(q.query_label) AS label, COUNT(*) AS queries
FROM sys_query_history q JOIN a ON a.session_id = q.session_id AND q.start_time >= a.t0 AND q.start_time < NVL(a.t1, GETDATE())
WHERE q.start_time > DATEADD(day, -1, GETDATE()) AND a.app <> ''
GROUP BY 1, 2, 3 ORDER BY queries DESC;
