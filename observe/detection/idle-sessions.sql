-- Purpose: list open database sessions that have been idle for at least <idle-minutes>, per database user, to
--   size CONNECTION LIMIT and SESSION TIMEOUT for agent users and to spot clients that hold connections open.
-- Post section: "The cost envelope: predictable by design" (CONNECTION LIMIT and SESSION TIMEOUT on each agent's
--   database user). Idea from the re:Post article "Best practice guide: preventing idle session connection
--   exhaustion in Amazon Redshift", rewritten and corrected:
--   https://repost.aws/articles/AR3KM9ai7YS1OioLypi6UqIg/best-practice-guide-preventing-idle-session-%E2%86%92-connection-exhaustion-in-amazon-redshift
-- Prerequisites: run as a superuser, a user with the sys:monitor role, or a user with SYSLOG ACCESS UNRESTRICTED.
--   A regular user sees only its own sessions.
-- Placeholders: <idle-minutes>.
-- Caveats (Redshift Serverless):
--   - A Data API session held open with SessionKeepAliveSeconds gets keep-alive queries from the Data API, so
--     it never looks idle here, even when the tool sends nothing; find those sessions with ListSessions.
--   - SYS_SESSION_HISTORY.status is 'active', 'closed' or 'timed_out' (with an underscore).
--   - Session IDs are reused, so idle time starts no earlier than the session's own start_time.
--   - On Serverless a session's start_time can move forward, so idle time is a lower bound.
SELECT TRIM(u.usename) AS db_user, s.session_id, TRIM(s.database_name) AS database_name,
       s.start_time AS session_start, s.session_timeout, q.last_query_end,
       DATEDIFF(minute, GREATEST(NVL(q.last_query_end, s.start_time), s.start_time), GETDATE()) AS idle_minutes
FROM sys_session_history s
JOIN pg_user u ON u.usesysid = s.user_id
LEFT JOIN (SELECT session_id, MAX(end_time) AS last_query_end
           FROM sys_query_history
           GROUP BY session_id) q ON q.session_id = s.session_id
WHERE TRIM(s.status) = 'active'
  AND s.end_time IS NULL
  AND s.user_id > 1                                       -- skip rdsdb, the system user
  AND DATEDIFF(minute, GREATEST(NVL(q.last_query_end, s.start_time), s.start_time), GETDATE()) >= <idle-minutes>
ORDER BY idle_minutes DESC;
