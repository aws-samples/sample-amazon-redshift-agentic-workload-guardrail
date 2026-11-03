-- Data API and Redshift MCP Server sessions per database user, last 7 days (run with sys:monitor)
SELECT TRIM(username) AS db_user,
       CASE WHEN query_text LIKE '%redshift-mcp-server%' THEN 'Redshift MCP Server' ELSE 'Data API' END AS client,
       COUNT(DISTINCT session_id) AS sessions, MAX(start_time) AS last_seen,
       username LIKE 'IAMR:agent-%' AS registered_agent
FROM sys_query_history
WHERE query_type = 'UTILITY'
  AND (query_text LIKE 'SET application_name TO ''awslabs/mcp/redshift-mcp-server%'
       OR query_text LIKE 'SET application_name = ''Amazon Redshift Data API%')
GROUP BY 1, 2, 5
ORDER BY registered_agent, sessions DESC;
