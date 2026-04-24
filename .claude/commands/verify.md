---
description: Verify the demo payoff — three Unity Catalog tables exist with rows.
allowed-tools: ["Bash(databricks tables list:*)", "Bash(databricks api post:*)", "Bash(databricks sql:*)"]
---

# /verify

Audience-facing "Payoff" beat: prove the diamond DAG produced real data in
Unity Catalog.

## What to do

1. **List the three expected tables** in `sandbox.dltdemo`:
   ```
   databricks tables list sandbox.dltdemo --profile julien-compass -o json
   ```
   Confirm `bronze_customers`, `bronze_orders`, and `silver_customer_summary`
   are all present.

2. **Sample the silver table** (the demo's headline output) — 5 rows, with
   columns formatted readably:
   ```
   databricks sql query \
     --profile julien-compass \
     --warehouse-id <SQL_WAREHOUSE_ID> \
     "SELECT * FROM sandbox.dltdemo.silver_customer_summary LIMIT 5"
   ```
   *If no SQL warehouse ID is configured for this profile, fall back to the
   Databricks UI: open `https://dbc-34be68e4-80e5.cloud.databricks.com` and
   tell the presenter to run the query in the SQL editor live.*

3. **Print a row-count summary**:
   - bronze_customers: N rows
   - bronze_orders: N rows
   - silver_customer_summary: N rows

   The silver count should equal the distinct customer count from bronze_customers
   (left-join, so every customer is represented).

4. **Point the presenter at the DAG view** with a clickable URL:
   ```
   https://dbc-34be68e4-80e5.cloud.databricks.com → Lakeflow Pipelines → dltdemo_pipeline
   ```
   The diamond DAG is the visual payoff — bronze_customers and bronze_orders
   feeding silver_customer_summary.

## Closing line for the presenter

Suggest a one-liner the presenter can deliver after the verify output renders:
> "Three Jira tickets, one command per phase, three Unity Catalog tables. The
> outer TDD loop drove the inner pipeline-runner loop. That's the toolchain."

## Guards

- If any of the three tables is missing, **don't** declare success. Tell the
  presenter exactly which table is missing and suggest peeking at the failed
  tackle session's pane (or running `/build-pipeline` again, since that step
  is idempotent).
- If the row counts are zero across the board, the pipeline ran but never
  ingested seed data — usually means the seed CSVs weren't uploaded to the
  Volume. Suggest `bash scripts/upload-seed-data.sh` and re-run `/build-pipeline`.
