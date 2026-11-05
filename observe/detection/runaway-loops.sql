-- Repeated query shapes or errors per agent user in the last 15 minutes (a heuristic)
WITH recent AS (
  SELECT TRIM(username) AS agent_user, status, generic_query_hash,
         REGEXP_REPLACE(TRIM(error_message), '[0-9]+', 'N') AS error_shape
  FROM sys_query_history
  WHERE start_time >= DATEADD(minute, -15, GETDATE())
    AND username LIKE 'IAMR:agent-%'
    AND query_type <> 'UTILITY'
    AND query_text NOT LIKE 'SELECT pg_last_query_id()%'   -- Data API bookkeeping
)
SELECT agent_user, 'same query shape' AS signal, TRIM(generic_query_hash) AS signature, COUNT(*) AS hits
FROM recent GROUP BY agent_user, generic_query_hash HAVING COUNT(*) >= 20
UNION ALL
SELECT agent_user, 'repeated error', error_shape, COUNT(*)
FROM recent WHERE status = 'failed' GROUP BY agent_user, error_shape HAVING COUNT(*) >= 5
ORDER BY hits DESC;
