ALTER SYSTEM SET metadata_security = true;  -- superuser only; applies to the whole cluster or workgroup
GRANT ACCESS CATALOG TO ROLE agent_monitoring;  -- a monitoring role that must still see every object
