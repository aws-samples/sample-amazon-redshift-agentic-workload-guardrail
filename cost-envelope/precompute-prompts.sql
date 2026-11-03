-- Purpose: run Redshift ML inference once per row. Compact prompts live in a materialized view, each
--   result is stored once, and each batch calls the model only for rows that have no stored result.
--   Redshift ML calls the model for every row the query processes, so the filter must remove rows
--   before the function runs: the anti-join below does; an outer LIMIT does not.
-- Post section: "Spend less per answer" (Redshift ML batches: precompute compact prompts).
-- Prerequisites: support.tickets (ticket_id, ticket_text, created_at); the support_summary_tool role and the
--   summarizer identity from model-spend-summarizer.sql; a Redshift ML IAM role on the namespace that may
--   invoke the model (for a cross-Region inference profile, the profile and each Region's foundation model).
-- Placeholders: <redshift-ml-role-arn>, <model-id> (for example us.amazon.nova-micro-v1:0), the prompt, 1000
--   (prompt length), 100 (rows per batch), 100 (maxTokens).

-- Part 1: run once as an administrator (a superuser, or the owner of support.tickets with CREATE MODEL)
CREATE EXTERNAL MODEL support.ticket_summary
FUNCTION ticket_summary
IAM_ROLE '<redshift-ml-role-arn>'
MODEL_TYPE BEDROCK
SETTINGS (MODEL_ID '<model-id>', PROMPT 'Summarize this support ticket in ten words or fewer:');
CREATE MATERIALIZED VIEW support.mv_ticket_prompts AS
SELECT ticket_id, created_at, LEFT(TRIM(ticket_text), 1000) AS prompt
FROM support.tickets;
CREATE TABLE support.ticket_summaries (ticket_id BIGINT, summary VARCHAR(2000), summarized_at TIMESTAMP);
GRANT SELECT ON support.mv_ticket_prompts TO ROLE support_summary_tool;
GRANT SELECT, INSERT ON support.ticket_summaries TO ROLE support_summary_tool;
GRANT EXECUTE ON MODEL support.ticket_summary TO ROLE support_summary_tool;
-- After REVOKE ASSUMEROLE ON ALL FROM PUBLIC FOR ALL (data-layer/exports-and-copies.sql), the tool can't call
-- the model until you grant the model's IAM role back for inference
GRANT ASSUMEROLE ON '<redshift-ml-role-arn>' TO ROLE support_summary_tool FOR EXTERNAL FUNCTION;

-- Part 2, each batch. First, as the materialized view's owner: pick up new tickets
REFRESH MATERIALIZED VIEW support.mv_ticket_prompts;
-- Then, as the summarizer identity: infer only rows without a stored result
INSERT INTO support.ticket_summaries
SELECT p.ticket_id, support.ticket_summary(p.prompt, object('maxTokens', 100))::VARCHAR, GETDATE()
FROM (SELECT m.ticket_id, m.prompt
      FROM support.mv_ticket_prompts m
      LEFT JOIN support.ticket_summaries s ON s.ticket_id = m.ticket_id
      WHERE s.ticket_id IS NULL
      ORDER BY m.ticket_id
      LIMIT 100) p;
