from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.monitor.query import LogsQueryClient, LogsQueryStatus
from datetime import timedelta

import subprocess
import os


# -------------------------------
# Load environment variables
# -------------------------------

load_dotenv()

WORKSPACE_ID = os.getenv("WORKSPACE_ID")

ZABBIX_SERVER = os.getenv("ZABBIX_SERVER")

ZABBIX_HOST = os.getenv("ZABBIX_HOST")


FAILED_KEY = "azure.failed.count"

WARNING_KEY = "azure.warning.count"


# -------------------------------
# Azure setup
# -------------------------------

credential = DefaultAzureCredential()

client = LogsQueryClient(credential)


# -------------------------------
# KQL Query
# -------------------------------

query = """
AzureDiagnostics
| where TimeGenerated > ago(35m)
| summarize
    failed = countif(Category == "JobLogs" and ResultType == "Failed"),
    warnings = countif(
        Category == "JobStreams"
        and ResultDescription contains "[WARN]"
    )
"""


# -------------------------------
# Execute query
# -------------------------------

response = client.query_workspace(
    workspace_id=WORKSPACE_ID,
    query=query,
    timespan=timedelta(minutes=35)
)

if response.status != LogsQueryStatus.SUCCESS:

    print("Query failed:", response)

    exit()


# -------------------------------
# Extract values
# -------------------------------

failed = 0
warnings = 0

for table in response.tables:

    for row in table.rows:

        failed = row[0]
        warnings = row[1]


print(f"Failed: {failed}")

print(f"Warnings: {warnings}")


# -------------------------------
# Send to Zabbix
# -------------------------------

subprocess.run([
    "zabbix_sender",
    "-z", ZABBIX_SERVER,
    "-s", ZABBIX_HOST,
    "-k", FAILED_KEY,
    "-o", str(failed)
])


subprocess.run([
    "zabbix_sender",
    "-z", ZABBIX_SERVER,
    "-s", ZABBIX_HOST,
    "-k", WARNING_KEY,
    "-o", str(warnings)
])


print("Metrics sent to Zabbix")