-- The summarization tool runs as its own identity (IAM role agent-support-summarizer),
-- which the agent's ad hoc SQL path can't use; only this identity can call the model
CREATE ROLE support_summary_tool;
GRANT USAGE ON SCHEMA support TO ROLE support_summary_tool;
GRANT SELECT (ticket_id, ticket_text, created_at) ON support.tickets TO ROLE support_summary_tool;
GRANT EXECUTE ON MODEL ticket_summary TO ROLE support_summary_tool;
-- After REVOKE ASSUMEROLE ON ALL FROM PUBLIC FOR ALL (data-layer/exports-and-copies.sql), grant the model's IAM role
-- back for inference; without it the call fails with "does not have ASSUMEROLE permission ... for EXTERNAL FUNCTION"
GRANT ASSUMEROLE ON '<redshift-ml-role-arn>' TO ROLE support_summary_tool FOR EXTERNAL FUNCTION;
GRANT ROLE support_summary_tool TO "IAMR:agent-support-summarizer";
-- Statement timeout for both agent-path users
ALTER USER "IAMR:agent-support" SET statement_timeout TO 120000;
ALTER USER "IAMR:agent-support-summarizer" SET statement_timeout TO 120000;
ALTER USER "IAMR:agent-support" CONNECTION LIMIT 10 SESSION TIMEOUT 300;  -- size the limit to the agent's concurrency
-- Attach the same RLS and masking policies to support_summary_tool for every table it reads
 
-- What the tool runs: bounded input (LEFT), rows sent to the model (inner LIMIT), and output (maxTokens)
-- maxTokens is case-sensitive (a lowercase maxtokens is silently ignored); if omitted, it defaults to the model's maximum
SELECT t.ticket_id,
       ticket_summary(LEFT(t.ticket_text, 4000), object('maxTokens', 200)) AS summary
FROM (SELECT ticket_id, ticket_text
      FROM support.tickets
      WHERE created_at >= DATEADD(day, -1, GETDATE())
      ORDER BY created_at DESC
      LIMIT 100) t;
