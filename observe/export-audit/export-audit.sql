-- Purpose: audit what agent-path users exported or copied: UNLOAD from SYS_UNLOAD_HISTORY, and CTAS,
--   INSERT and UNLOAD attempts (including failed ones) from SYS_QUERY_HISTORY. Bucket writes themselves
--   are in CloudTrail S3 data events (cloudtrail-s3-data-events.sh and cloudtrail-s3-writes.sql).
-- Post section: "What the agent keeps: database-side exports and copies" (audit exports).
-- Prerequisites: run as a superuser or a user with the sys:monitor role; a regular user sees only its own rows.
-- Placeholders: 'IAMR:agent-%' (your agent naming convention), the 7-day window.

-- 1. UNLOAD by agent-path users, last 7 days
SELECT TRIM(u.usename) AS agent_user, h.query_id, h.start_time, TRIM(h.status) AS status,
       TRIM(h.file_format) AS file_format, TRIM(h.unloaded_location) AS unloaded_location,
       h.unloaded_rows, h.unloaded_files_count, h.unloaded_files_size, TRIM(h.error_message) AS error_message
FROM sys_unload_history h
JOIN pg_user u ON u.usesysid = h.user_id
WHERE h.start_time >= DATEADD(day, -7, GETDATE())
  AND u.usename LIKE 'IAMR:agent-%'
ORDER BY h.start_time DESC;

-- 2. CTAS, INSERT and UNLOAD statements by agent-path users, last 7 days, with failures
SELECT TRIM(u.usename) AS agent_user, h.query_id, h.start_time, TRIM(h.query_type) AS query_type,
       TRIM(h.status) AS status, h.returned_rows, LEFT(TRIM(h.query_text), 200) AS query_text,
       LEFT(TRIM(h.error_message), 200) AS error_message
FROM sys_query_history h
JOIN pg_user u ON u.usesysid = h.user_id
WHERE h.start_time >= DATEADD(day, -7, GETDATE())
  AND u.usename LIKE 'IAMR:agent-%'
  AND h.query_type IN ('CTAS', 'INSERT', 'UNLOAD')
ORDER BY h.start_time DESC;
