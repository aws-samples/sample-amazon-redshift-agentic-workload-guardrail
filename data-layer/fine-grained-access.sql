-- Rows: the support agent sees one region
CREATE RLS POLICY rls_region_west
WITH (region VARCHAR(16))
USING (region = 'west');
ATTACH RLS POLICY rls_region_west ON sales.orders TO ROLE agent_support;
ALTER TABLE sales.orders ROW LEVEL SECURITY ON;
 
-- Columns: no PII from the customer table
GRANT SELECT (customer_id, segment, region, signup_date)
  ON sales.customers TO ROLE agent_support;
 
-- Values: last four digits of a card, written as a SQL expression
CREATE MASKING POLICY mask_card_last4
WITH (card_number VARCHAR(16))
USING ('XXXXXXXXXXXX' || RIGHT(card_number, 4));
ATTACH MASKING POLICY mask_card_last4
  ON sales.payments(card_number) TO ROLE agent_support;
