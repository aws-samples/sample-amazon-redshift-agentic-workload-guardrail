# Purpose: run the Amazon Redshift MCP Server's review_cluster health check on a schedule, without an AI
#   assistant: start the server over stdio, call review_cluster once, save the result as JSON, and exit 1
#   when there are findings so the scheduler (or a wrapper) can alert.
# Post section: "Observe and prove" (the remaining configuration, including scheduled review_cluster health checks).
# Prerequisites:
#   - Python 3.10+, uv (for uvx), and the MCP Python SDK 1.x: pip install "mcp>=1,<2".
#   - A monitoring IAM role with the data plane policy's Discover and RunSqlOnOneWorkgroup statements plus
#     redshift-data:DescribeStatement and GetStatementResult (access-layer/shared/agent-data-plane-policy.json),
#     and an AWS profile for it (see access-layer/shared/aws-config-example.ini).
#   - That role's database user holds sys:monitor: GRANT ROLE sys:monitor TO "IAMR:<monitoring-role-name>";
#   - These permissions (the three data plane statements, nothing else) and sys:monitor are enough for
#     review_cluster with awslabs.redshift-mcp-server 0.1.2 on Redshift Serverless.
# Placeholders: <agent-workgroup>, <monitoring-profile>, <region>, dev (database), the output folder.
# Schedule it, for example daily at 06:00:
#   cron (Linux, macOS):  0 6 * * * cd /opt/redshift-review && python3 scheduled_review_cluster.py >> review.log 2>&1
#   Windows Task Scheduler:
#     schtasks /Create /SC DAILY /ST 06:00 /TN redshift-review-cluster /TR "python C:\redshift-review\scheduled_review_cluster.py"
import asyncio
import datetime
import json
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

WORKGROUP = "<agent-workgroup>"
PROFILE = "<monitoring-profile>"
REGION = "<region>"
DATABASE = "dev"
SERVER = ["uvx", "awslabs.redshift-mcp-server@0.1.2"]  # pin a version; change it only after you review the new one
OUT_DIR = os.path.dirname(os.path.abspath(__file__))


async def review() -> dict:
    env = dict(os.environ, AWS_PROFILE=PROFILE, AWS_REGION=REGION, FASTMCP_LOG_LEVEL="ERROR")
    params = StdioServerParameters(command=SERVER[0], args=SERVER[1:], env=env)
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.call_tool("review_cluster", {
                "cluster_identifier": WORKGROUP, "cluster_type": "serverless", "database_name": DATABASE})
            if result.isError:
                raise RuntimeError(" ".join(c.text for c in result.content if hasattr(c, "text")))
            if result.structuredContent is not None:
                return result.structuredContent
            return json.loads(result.content[0].text)


def main() -> int:
    review_result = asyncio.run(review())
    data = review_result.get("result", review_result)  # FastMCP may wrap a model result in {"result": ...}
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(OUT_DIR, "review-%s.json" % stamp)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, default=str)
    findings = data.get("findings", [])
    print("signals_evaluated=%s findings=%d file=%s" % (data.get("signals_evaluated"), len(findings), path))
    for fnd in findings:
        print("  %s: %s %s, recommendations %s" % (fnd.get("signal_name"), fnd.get("affected_row_count"),
                                                   fnd.get("unit"), fnd.get("recommendation_ids")))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
