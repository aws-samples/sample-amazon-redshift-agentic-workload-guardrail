-- One database role per agent: privileges go to the role, never to the user
CREATE ROLE agent_support;
GRANT USAGE ON SCHEMA sales TO ROLE agent_support;
GRANT SELECT ON sales.orders, sales.payments TO ROLE agent_support;
 
-- Grant the role to the agent's database user once it exists (after its first sign-in)
GRANT ROLE agent_support TO "IAMR:agent-support";
