from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.monitor.query import LogsQueryClient, LogsQueryStatus
from datetime import timedelta

import psycopg2
import os


# -------------------------------
# Load environment variables
# -------------------------------

load_dotenv()

DB_HOST = os.getenv("DB_HOST")
DB_PORT = int(os.getenv("DB_PORT"))
DB_NAME = os.getenv("DB_NAME")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")

WORKSPACE_ID = os.getenv("WORKSPACE_ID")


# -------------------------------
# Azure setup
# -------------------------------

credential = DefaultAzureCredential()

client = LogsQueryClient(credential)


# -------------------------------
# PostgreSQL connection
# -------------------------------

conn = psycopg2.connect(
    host=DB_HOST,
    port=DB_PORT,
    database=DB_NAME,
    user=DB_USER,
    password=DB_PASSWORD
)

cursor = conn.cursor()


# -------------------------------
# KQL Query
# -------------------------------

query = """
AzureDiagnostics
| where Category == "JobStreams"
| where TimeGenerated > ago(1d)
| where ResultDescription startswith "{"
| extend p = parse_json(ResultDescription)
| where p.Source == "automation-script"
| project
    TimeGenerated,
    Username = tostring(p.Username),
    Email = tostring(p.Email),
    Department = tostring(p.Department),
    JobTitle = tostring(p.JobTitle),
    Manager = tostring(p.Manager),
    Status = tostring(p.Status),
    Warnings = tostring(coalesce(p.Warnings, "[]"))
| order by TimeGenerated asc
"""


# -------------------------------
# Execute query
# -------------------------------

response = client.query_workspace(
    workspace_id=WORKSPACE_ID,
    query=query,
    timespan=timedelta(days=1)
)

if response.status != LogsQueryStatus.SUCCESS:

    print("Query failed:", response)

    exit()


# -------------------------------
# Insert into PostgreSQL
# -------------------------------

inserted = 0

try:

    for table in response.tables:

        for row in table.rows:

            time_generated = row[0]
            username = row[1]
            email = row[2]
            department = row[3]
            job_title = row[4]
            manager = row[5]
            status = row[6]
            warnings = row[7] if row[7] else "[]"

            cursor.execute("""
                INSERT INTO logs (
                    time_generated,
                    username,
                    email,
                    department,
                    job_title,
                    manager,
                    status,
                    warnings
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT DO NOTHING
            """, (
                time_generated,
                username,
                email,
                department,
                job_title,
                manager,
                status,
                str(warnings)
            ))

            if cursor.rowcount > 0:
                inserted += 1

    conn.commit()

finally:

    cursor.close()
    conn.close()


print(f"Inserted {inserted} new rows")