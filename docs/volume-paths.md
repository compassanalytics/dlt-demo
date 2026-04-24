# Volume Paths — DLT-Demo

Single source of truth for Unity Catalog Volume paths used across the DLT-Demo.
Downstream tickets (#005 DLT pipeline, #007 runbook, #008 dry-run, #009
reset-demo) reference these paths — do NOT change them without updating all
dependents.

## Seed data volume

| Attribute | Value |
|---|---|
| Three-part name | `sandbox.dltdemo.raw` |
| Catalog | `sandbox` |
| Schema | `dltdemo` |
| Volume name | `raw` |
| Volume type | `MANAGED` |
| Profile | `julien-compass` |
| Created by | `scripts/upload-seed-data.sh` (idempotent) |

## File paths inside the volume

| File | Full path (for DLT pipeline `spark.read...load()`) |
|---|---|
| Customers | `/Volumes/sandbox/dltdemo/raw/customers.csv` |
| Orders | `/Volumes/sandbox/dltdemo/raw/orders.csv` |

## Source CSVs (repo-local, committed)

| File | Path |
|---|---|
| Customers | `databricks/src/seed_data/customers.csv` |
| Orders | `databricks/src/seed_data/orders.csv` |

## Why `sandbox` and not `julien_compass`?

Ticket #003 (DAB scaffold) verified via `databricks catalogs list --profile
julien-compass` that the accessible sandbox catalog is named `sandbox`. The
early PRD drafts and ticket #004 scope used a placeholder name `julien_compass`
which turned out not to match the actual workspace. `sandbox` is the real name
and matches `databricks/databricks.yml` bundle variables.
