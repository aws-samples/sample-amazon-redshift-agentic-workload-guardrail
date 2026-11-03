-- Purpose: confirm that the RedshiftDbRoles tag maps the agent's IAM role to its database role at sign-in.
-- Post section: "Data layer: decide what the agent can reach" (the RedshiftDbRoles tag on Redshift Serverless).
-- Prerequisites: redshiftdbroles-tag.sh applied; the agent signs in again after the tag change
--   (a new Data API call or a new connection), because the tag is read at sign-in.
-- Placeholders: agent_support (database role), sales.orders (a table the role can read).
-- The tag grants a session role: it holds for the session only and is not stored as a grant, so it
-- doesn't appear in SVV_USER_GRANTS, SHOW GRANTS FOR <user>, or HAS_TABLE_PRIVILEGE(<user>, ...) run by
-- someone else. Check it from the agent's own session (part 1), and audit the role's grants and the
-- IAM tag instead of the user's grants (part 2 and redshiftdbroles-tag.sh).

-- Part 1: run as the agent (through the Data API or the agent's own connection)
SELECT current_user;                                        -- IAMR:<agent-role-name>
SELECT user_is_member_of(current_user, 'agent_support');    -- true in a session that got the role
SELECT has_table_privilege('sales.orders', 'select');       -- true through the role

-- Part 2: run as an administrator: what the session role grants
SHOW GRANTS FOR ROLE agent_support;
