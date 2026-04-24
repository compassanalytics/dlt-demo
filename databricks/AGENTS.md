# Declarative Automation Bundles Project

This project uses Declarative Automation Bundles (formerly Databricks Asset Bundles) for deployment.

## Prerequisites

Install the Databricks CLI (>= v0.288.0) if not already installed:
- macOS: `brew tap databricks/tap && brew install databricks`
- Linux: `curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh`
- Windows: `winget install Databricks.DatabricksCLI`

Verify: `databricks -v`

## For AI Agents

Read the `databricks` skill for CLI basics, authentication, and deployment workflow.
Read the `databricks-pipelines` skill for pipeline-specific guidance.

If skills are not available, install them: `databricks experimental aitools skills install`

## Project Context

- **Profile**: `julien-compass` (workspace `dbc-34be68e4-80e5.cloud.databricks.com`)
- **Catalog**: `sandbox` (Unity Catalog; verified via `databricks catalogs list --profile julien-compass`)
- **Schema**: `dltdemo`
- **Bundle target**: `dev` only (mode: development, default: true)
- **Compute**: serverless pipeline — no cluster sizing required
- **Pipeline source root**: `src/pipelines/` (1 dataset per file convention)
- **Seed data root**: `src/seed_data/` (reserved for CSV seed files, ticket 004)

## Common Commands

Run from the `databricks/` directory:

```bash
databricks bundle validate --profile julien-compass
databricks bundle deploy   --profile julien-compass
databricks bundle run dltdemo_pipeline --profile julien-compass
```
