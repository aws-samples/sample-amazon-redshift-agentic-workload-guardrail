# A custom MCP server with one fixed, parameterized tool.
# The agent can choose a region and dates; it can't change the SQL, the table, or the identity.
# FastMCP (mcp.server.fastmcp) is in the MCP Python SDK 1.x only, so install with requirements.txt (mcp>=1,<2).
# Post section: "Data plane: a narrow tool surface on every path" (Custom MCP server).
# Prerequisites: run the server under its own IAM role with an agent- name (database user IAMR:agent-sales-metrics)
# and the data plane policy; grant that user SELECT on sales.v_daily_revenue only. If RLS is on for sales.orders,
# attach a policy for that user too. Replace agents-wg and dev with your workgroup and database.
# Each tool sets a fixed StatementName and SQL comment, so CloudTrail, ListStatements and query history name the tool.
import time
from datetime import date

import boto3
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("sales-metrics")
rsd = boto3.client("redshift-data")  # the server's own IAM role, signed in as IAMR:agent-sales-metrics

REGIONS = {"west", "east", "central"}
SQL = """/* app=sales-metrics tool=daily_revenue */ SELECT order_date, SUM(total_amount) AS revenue
FROM sales.v_daily_revenue
WHERE region = :region AND order_date BETWEEN :start_date AND :end_date
GROUP BY order_date ORDER BY order_date LIMIT 400"""


def wait_and_fetch(statement_id: str) -> list[dict]:
    """Poll describe_statement until the statement ends, then return its rows from get_statement_result."""
    while (desc := rsd.describe_statement(Id=statement_id))["Status"] not in ("FINISHED", "FAILED", "ABORTED"):
        time.sleep(0.5)
    if desc["Status"] != "FINISHED":
        raise RuntimeError(desc.get("Error", desc["Status"]))
    rows = rsd.get_statement_result(Id=statement_id)["Records"]
    return [{"order_date": r[0]["stringValue"], "revenue": r[1]["stringValue"]} for r in rows]


@mcp.tool()
def daily_revenue(region: str, start_date: str, end_date: str) -> list[dict]:
    """Daily revenue for one sales region over at most 90 days (dates as YYYY-MM-DD)."""
    start, end = date.fromisoformat(start_date), date.fromisoformat(end_date)
    if region not in REGIONS or not 0 <= (end - start).days <= 90:
        raise ValueError("region must be west, east, or central, and the range at most 90 days")
    stmt = rsd.execute_statement(
        WorkgroupName="agents-wg", Database="dev", Sql=SQL,
        StatementName="sales-metrics:daily_revenue",  # fixed per tool: CloudTrail and ListStatements name the tool
        Parameters=[{"name": "region", "value": region},
                    {"name": "start_date", "value": start.isoformat()},
                    {"name": "end_date", "value": end.isoformat()}])
    return wait_and_fetch(stmt["Id"])


if __name__ == "__main__":
    mcp.run()
