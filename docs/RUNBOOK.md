# DLT-Demo Presenter Runbook

A beat-by-beat operational guide for the TDD + Databricks Compass live demo.

---

## Pre-Demo (~30s)

**Goal:** Verify all six systems are healthy before the audience arrives.

```bash
bash scripts/health-check.sh
```

**Audience sees:** Terminal scrolling six `[PASS]` lines, then `All checks passed. Demo ready.`

**If > 60s:** One of the probes is timing out (likely Databricks auth or Jira). Abort and fix before starting.

> **Fallback — Databricks auth expired**
> ```bash
> databricks auth login --profile julien-compass
> ```
> Re-run `health-check.sh`.

> **Fallback — Jira API down**
> Skip live Jira import. Use pre-seeded static fixture:
> ```bash
> cp scripts/jira_fixture.json /tmp/jira_fixture.json
> # Presenter narrates: "Normally we'd fetch live tickets; today we'll show the local fixture."
> ```

---

## Setup (~2 min)

**Presenter does:**

1. Open Claude Code in `DLT-Demo/` root.
2. **Say:** *"This is a live TDD + Databricks Compass demo. We'll turn three Jira tickets into a running DLT pipeline with a diamond dependency graph."*
3. Show the repo layout:
   - `scripts/` — health-check, reset, seed
   - `databricks/src/pipelines/` — `bronze_a.py`, `bronze_b.py`, `silver_c.py`, `main.py`
   - `databricks/src/seed_data/` — `customers.csv`, `orders.csv`
   - `.claude/skills/jira-to-tdd/SKILL.md` — the Jira-to-TDD skill
4. **Say:** *"Everything starts clean."*

**Audience sees:** A clean repo with no `.tdd/backlog/*.md` tickets.

**If > 4 min:** You're over-explaining. Jump straight to health-check and start Act 1.

---

## Act 1 — Jira → TDD (~5 min)

**Presenter prompt (exact):**

> **"Read the DLTDEMO tickets from Jira and convert them into TDD tickets."**

Or type:
```
/jira-to-tdd DLTDEMO
```

**What happens:**
- Skill fetches 3 issues from Jira (`DLTDEMO-1`, `DLTDEMO-2`, `DLTDEMO-3`)
- Resolves dependency graph: C blocked by A and B (diamond)
- Spawns parallel `create-ticket` agents
- Prints completion table: Jira Key → TDD Ticket mapping with `blocked_by` wired

**Audience sees:**
```
| Jira Key  | Summary               | TDD Ticket | Blocked By (TDD) | Status  |
|-----------|-----------------------|------------|------------------|---------|
| DLTDEMO-1 | Create bronze table A | #001       | —                | Created |
| DLTDEMO-2 | Create bronze table B | #002       | —                | Created |
| DLTDEMO-3 | Create silver table C | #003       | #001, #002       | Created |
```

**Verify:**
```bash
ls .tdd/backlog/
```

**If > 8 min:** Jira API is slow or `create-ticket` agents are stuck.

> **Fallback — Tackle session stuck**
> Press `Ctrl+C`, re-prompt: *"Continue creating the remaining TDD tickets from DLTDEMO."* Or manually tackle the stuck ticket by number.

---

## Act 2 — Parallel Tackle A + B (~8 min)

**Presenter prompt:**

> **"/ralph-tackle"**

**What happens:**
- TDD orchestrator scans `.tdd/backlog/`
- #001 (A) and #002 (B) have no blockers → spawn in parallel
- #003 (C) is blocked by #001 and #002 → waits
- Each tackle session uses the `pipeline-runner` skill:
  1. Validate DLT bundle: `databricks bundle validate --profile julien-compass`
  2. Deploy: `databricks bundle deploy --profile julien-compass`
  3. Run pipeline: `databricks bundle run dltdemo_pipeline --profile julien-compass`
  4. Read errors, fix code, retry

**Presenter narrates:**
> *"Watch this — A and B have no dependencies, so they run in parallel. C waits. Each tackle is a full validate→deploy→run loop."*

**Audience sees:** Two parallel Claude Code tackle sessions, each editing `bronze_a.py` and `bronze_b.py`, deploying, and running.

**Verify progress:**
```bash
ls .tdd/in-progress/
```

**If > 12 min:** One tackle session may be stuck in a retry loop.

> **Fallback — Tackle session stuck**
> `Ctrl+C` the stuck session, then tackle individually:
> ```
> /tackle 001
> /tackle 002
> ```

---

## Act 3 — Tackle C + The Nested Loop (~5 min)

**Presenter narrates the nested agentic loop:**

> *"Here's the architecture we're showcasing. The outer loop is TDD's explore→plan→implement→review cycle, driven per ticket by the TDD orchestrator. The inner loop is databricks-compass's `pipeline-runner`: validate the DLT bundle, deploy to the workspace, run the pipeline, read errors, fix code, retry. The outer TDD loop drives the inner pipeline-runner loop — each implementation phase triggers a full validate→deploy→run→fix→retry cycle. This is the agentic recursion the demo showcases."*

**Presenter prompt (once A and B show completed):**

> **"/ralph-tackle"** or **"/tackle 003"**

**What happens:**
- C unblocks (both blockers now in `.tdd/completed/`)
- Tackle session opens for `silver_c.py`
- `pipeline-runner` validates, deploys, runs the full diamond DAG

**Audience sees:** `silver_c.py` being edited, pipeline running with A and B as upstream dependencies.

**Verify:**
```bash
ls .tdd/completed/
```

**If > 8 min:** Pipeline may be cold-starting or stuck on DLT initialization.

> **Fallback — DLT cold-start latency**
> Narrate: *"DLT serverless pipelines take ~60s to initialize on first run — this is normal."* Keep talking about the dependency graph while it warms up. Pre-warm during health-check if possible by running a no-op validation.

---

## Payoff (~2 min)

**Presenter does:**

1. Open Databricks UI → `https://dbc-34be68e4-80e5.cloud.databricks.com`
2. Navigate to **Delta Live Tables** → `dltdemo_pipeline`
3. **Say:** *"Here's the diamond DAG — bronze_customers and bronze_orders feed silver_customer_summary."*
4. Run a query on `silver_customer_summary`:
   ```sql
   SELECT * FROM sandbox.dltdemo.silver_customer_summary LIMIT 10;
   ```
5. Show `.tdd/completed/`:
   ```bash
   ls .tdd/completed/
   ```

**Audience sees:**
- Live DAG graph: `bronze_customers` → `silver_customer_summary` ← `bronze_orders`
- Real rows from the silver table
- Three completed TDD tickets

**If > 4 min:** The query returned slowly or the UI is loading. Keep narrating — don't let silence kill the energy.

---

## Q&A

**Anticipated questions and short answers:**

- *"What if Jira changes mid-demo?"* — `seed-jira.sh` is idempotent; re-run it.
- *"Can this work with 30 tickets?"* — Yes; topo sort + parallel spawn scales linearly.
- *"What if the pipeline fails?"* — `pipeline-runner` reads errors, fixes, retries. That's the inner loop.
- *"Is this safe to run in production?"* — Demo uses `dev` mode and `sandbox` catalog. Production would target a `prod` target.

---

## `--hard-mode` Variant (Intentional Failure + Recovery)

**When to use:** If you have extra time (~+3 min) and want to show fix-and-retry.

**Setup (before health-check):**
```bash
bash scripts/seed-jira.sh --hard-mode
```

This seeds DLTDEMO-3 with `customerid` (no underscore) instead of `customer_id`.

**Demo flow:**
1. Run Acts 1–3 normally.
2. When C tackles, `pipeline-runner` deploys and runs.
3. Pipeline fails with a schema mismatch: `customerid` not found in `bronze_orders`.
4. **Say:** *"Watch — the agent reads the error, fixes the typo, and retries."*
5. Tackle session edits `silver_c.py`: changes `customerid` → `customer_id`.
6. `pipeline-runner` redeploys and succeeds.

**Audience sees:** A real failure, automated diagnosis, one-line fix, green pipeline.

> **Fallback — Recovery fails**
> If the auto-fix doesn't trigger, manually prompt: *"The error says 'customerid' — change it to 'customer_id' in silver_c.py and retry."*

---

## Quick Reference

| Command | Purpose |
|---------|---------|
| `bash scripts/health-check.sh` | Pre-demo validation (6 checks) |
| `bash scripts/reset-demo.sh` | Idempotent teardown (<120s) |
| `bash scripts/seed-jira.sh` | Provision DLTDEMO + 3 issues |
| `bash scripts/seed-jira.sh --hard-mode` | Seed with intentional typo |
| `databricks bundle validate --profile julien-compass` | Validate DAB (run from `databricks/`) |
| `databricks bundle deploy --profile julien-compass` | Deploy pipeline |
| `databricks bundle run dltdemo_pipeline --profile julien-compass` | Run pipeline |
| `databricks auth login --profile julien-compass` | Fix expired auth |

**Key paths:**
- Bundle: `databricks/`
- Pipeline entry: `databricks/src/pipelines/main.py`
- Bronze A: `databricks/src/pipelines/bronze_a.py` (`bronze_customers`)
- Bronze B: `databricks/src/pipelines/bronze_b.py` (`bronze_orders`)
- Silver C: `databricks/src/pipelines/silver_c.py` (`silver_customer_summary`)
- Seed data: `databricks/src/seed_data/customers.csv`, `orders.csv`
- Jira skill: `.claude/skills/jira-to-tdd/SKILL.md`
- TDD backlog: `.tdd/backlog/`
- TDD completed: `.tdd/completed/`

**Workspace:** `https://dbc-34be68e4-80e5.cloud.databricks.com`  
**Profile:** `julien-compass`  
**Catalog:** `sandbox`  
**Schema:** `dltdemo`  
**Pipeline:** `dltdemo_pipeline`

---

## Changelog

| Date | Version | Change |
|------|---------|--------|
| 2026-04-22 | 1.0 | Initial runbook covering Pre-demo, Setup, Acts 1–3, Payoff, Q&A, hard-mode variant, and all fallbacks. |
