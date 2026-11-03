# Purpose: map an agent's IAM role to its database role at sign-in with the RedshiftDbRoles tag, so the
#   privileges live on one database role (agent_support) and nobody runs GRANT ROLE for each agent user.
# Post section: "Data layer: decide what the agent can reach" (the RedshiftDbRoles tag on Redshift Serverless).
# Prerequisites:
#   - Amazon Redshift Serverless. The tag is read when the role signs in through GetCredentials, which the
#     Data API and the Redshift MCP Server use.
#   - The database role exists and holds the privileges (agent-role.sql: CREATE ROLE agent_support, GRANT ...).
#     Skip that file's GRANT ROLE ... TO "IAMR:agent-support" line when you use the tag.
#   - Run these commands as an IAM administrator, not as the agent.
# Placeholders: <agent-role-name> (for example agent-support), agent_support (your database role name).
# Verify with redshiftdbroles-verify.sql.

# Tag the agent's IAM role. Separate several database roles with colons (agent_support:agent_reports).
# A role name that doesn't exist in the database is ignored.
aws iam tag-role --role-name <agent-role-name> \
  --tags Key=RedshiftDbRoles,Value=agent_support

# The Redshift guide lists tag:GetResources and tag:GetTagKeys for roles that sign in with IAM credentials.
# Sign-in through the Data API maps the role without them; add them for IAM-authenticated drivers.
aws iam put-role-policy --role-name <agent-role-name> \
  --policy-name redshiftdbroles-tag-read \
  --policy-document file://redshiftdbroles-tag-permissions.json

# Audit which database roles an IAM role gets. The mapping is a session role, so it doesn't appear
# in the database's grant views for the user.
aws iam list-role-tags --role-name <agent-role-name>

# Remove the mapping. The next sign-in no longer gets the role; nothing to revoke in the database.
aws iam untag-role --role-name <agent-role-name> --tag-keys RedshiftDbRoles
