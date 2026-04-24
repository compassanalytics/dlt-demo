---
description: Initialize the DLT-Demo environment — run health-check and seed Jira (idempotent).
argument-hint: "[--hard-mode]"
allowed-tools: ["Bash(bash scripts/health-check.sh:*)", "Bash(bash scripts/seed-jira.sh:*)"]
---

# /demo-init

Initialize the DLT-Demo for a presentation. Runs the two preflight scripts in order
and reports status concisely.

## What to do

1. Run **health-check** — all 6 probes must pass:
   ```
   bash scripts/health-check.sh
   ```
   If any check fails, **stop** and tell the presenter exactly which probe failed.
   Common failures and remediation are in `docs/RUNBOOK.md` ("Pre-Demo" section).

2. Run **seed-jira** — idempotent provisioning of the DLTDEMO project + 3 issues.
   If the user passed `--hard-mode`, forward that flag (seeds DLTDEMO-3 with a
   deliberate `customerid` typo to enable the failure-and-recovery storyline).
   ```
   bash scripts/seed-jira.sh [--hard-mode]
   ```

3. Print a one-paragraph readiness summary so the presenter can see we are green:
   - Number of Jira issues seeded (should be 3 created or 3 reused).
   - Whether hard-mode is active.
   - Confirmation that `.tdd/backlog/` is empty (a clean slate for `/ingest-jira`).

## Don't

- Don't proceed past health-check failures. The whole point of the script is to
  prevent a doomed demo run.
- Don't seed more than 3 issues. If the script reports "extra issues found,"
  tell the presenter to run `bash scripts/reset-demo.sh` first.
