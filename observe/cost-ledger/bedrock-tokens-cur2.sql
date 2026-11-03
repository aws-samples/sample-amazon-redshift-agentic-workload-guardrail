-- Purpose: Amazon Bedrock token usage and cost per day, per calling IAM role and per agent tag, from a
--   CUR 2.0 export with caller identity data (Amazon Athena).
-- Post section: "Attribute compute and inference costs" (Bedrock tokens come from CUR 2.0 by principal).
-- Prerequisites:
--   - A CUR 2.0 data export created with "Include caller identity (IAM principal) allocation data"
--     (table property INCLUDE_IAM_PRINCIPAL_DATA=TRUE), and an Athena table over it.
--   - For the tag column: the agent-id tag on each IAM role that calls Bedrock (for Redshift ML, the IAM_ROLE
--     in CREATE EXTERNAL MODEL), activated as the cost allocation tag iamPrincipal/agent-id. Tags appear for
--     activation only after the tagged role has called Bedrock, and activation can take up to 24 hours each.
-- Placeholders: <cur_database>.<cur_table>, <start-date> and <end-date> (YYYY-MM-DD), the tag key agent-id.
-- Notes: line_item_iam_principal holds a role session ARN for assumed roles; the regexp folds sessions into
--   the role. usage_amount is in pricing_unit. Models sold through AWS Marketplace can bill under another
--   product code than AmazonBedrock.
SELECT DATE_TRUNC('day', line_item_usage_start_date) AS usage_day,
       regexp_replace(line_item_iam_principal,
                      '^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/.*$', 'arn:aws:iam::$1:role/$2') AS principal,
       element_at(tags, 'iamPrincipal/agent-id') AS agent_id,
       line_item_usage_type,
       pricing_unit,
       SUM(line_item_usage_amount) AS usage_amount,
       SUM(line_item_unblended_cost) AS unblended_cost
FROM <cur_database>.<cur_table>
WHERE line_item_usage_start_date >= TIMESTAMP '<start-date> 00:00:00'
  AND line_item_usage_start_date < TIMESTAMP '<end-date> 00:00:00'
  AND line_item_product_code = 'AmazonBedrock'
  AND (line_item_usage_type LIKE '%input-token%' OR line_item_usage_type LIKE '%output-token%')
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, unblended_cost DESC;
