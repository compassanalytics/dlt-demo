# DLT-Demo

A repeatable, self-contained live demo that showcases the **Compass Claude Code toolchain** — `ticket-driven-dev`, `databricks-compass`, and the Jira skills — composing into an end-to-end data engineering workflow.

In ~20 minutes, a presenter takes three Jira tickets and turns them into a running Lakeflow Declarative Pipeline (formerly DLT) on Databricks, with the agent loop visibly building each table from scratch.

> **Audience-facing artifact:** the *composition* of the plugins, not any single one. The story is "look how naturally these compose."

---

## The narrative beats

1. **Three Jira tickets** in `DLTDEMO` describing bronze A, bronze B, silver C (diamond dependency).
2. One Claude Code prompt: *"Read the DLTDEMO tickets and convert them into TDD tickets."*
3. The `jira-to-tdd` skill spawns parallel `create-ticket` agents → populates `.tdd/backlog/` with dependency-wired tickets.
4. `/ralph-tackle` fans out — A and B run **in parallel**, C waits for both.
5. Each tackle session uses `pipeline-runner` to **validate → deploy → run → read errors → fix → retry**.
6. **Payoff:** a diamond DAG renders in the Databricks UI; three Unity Catalog tables exist; three TDD tickets in `completed/`.

This is the **nested agentic loop** — outer TDD loop drives inner pipeline-runner loop. That's the architectural story.

---

## Three demo modes — pick one for the room

| Mode | When to use | What you type |
|------|-------------|---------------|
| **Walkthrough** (manual) | Engineering audiences who want to *see Claude reason* through each step | Verbatim prompts from [`docs/RUNBOOK.md`](docs/RUNBOOK.md) |
| **Guided** (slash commands) | Mixed audiences; non-author presenters; the boss running solo | `/demo-init` → `/ingest-jira` → `/ingest-docs` → `/build-pipeline` → `/verify` |
| **Auto** (one-shot, headless) | Pitch demos for non-technical clients; "set it and watch it run" | `bash scripts/demo-auto.sh` |

Each mode lands the same payoff (diamond DAG in Databricks UI). Pick by audience and your tolerance for surprise.

## Presenter quick-start

> Full beat-by-beat script with timings and fallbacks: **[`docs/RUNBOOK.md`](docs/RUNBOOK.md)** ← read this before presenting.

### One-time setup

```bash
git clone https://github.com/compassanalytics/dlt-demo.git
cd dlt-demo

# Required environment variables (put them in your shell profile):
export JIRA_DOMAIN=compassdataanalytics.atlassian.net
export JIRA_EMAIL=<your-email>
export JIRA_API_TOKEN=<token from id.atlassian.com>

# Databricks profile (one-time):
databricks auth login --profile julien-compass
```

### Pre-demo (~30 seconds)

```bash
bash scripts/health-check.sh   # 6 PASSes = demo ready
bash scripts/seed-jira.sh      # idempotent — populates DLTDEMO project
```

### Demo flow (~20 minutes)

| Act | Time | Presenter says / types | What audience sees |
|-----|------|------------------------|--------------------|
| **Setup** | 2 min | "Three Jira tickets describe a diamond data pipeline." | Clean repo, three Jira issues |
| **Act 1** | 5 min | *"Read the DLTDEMO tickets and convert them into TDD tickets."* | Skill spawns parallel agents, populates `.tdd/backlog/` |
| **Act 2** | 8 min | `/ralph-tackle` | Two parallel tackle sessions edit `bronze_a.py` and `bronze_b.py` |
| **Act 3** | 5 min | `/ralph-tackle` (or `/tackle 003`) | C unblocks; pipeline-runner deploys diamond DAG |
| **Payoff** | 2 min | Open Databricks UI → DLT pipeline → query `silver_customer_summary` | Live DAG + real rows |

### Reset between runs (~120s)

```bash
bash scripts/reset-demo.sh     # tears Jira, .tdd/, pipeline, schema back to clean baseline
```

### Auto mode (one command, headless)

```bash
bash scripts/demo-auto.sh                 # full happy-path run
bash scripts/demo-auto.sh --hard-mode     # fail-and-recover storyline
```

Drives the entire demo via `claude --print --permission-mode acceptEdits`.
Bash handles preflight + final assertion; Claude handles the four demo phases
in between. Transcript written to `artifacts/demo-auto-<timestamp>.log` for
post-run review. See `bash scripts/demo-auto.sh --help` for all flags.

### Optional: `--hard-mode` (failure + recovery storyline)

```bash
bash scripts/seed-jira.sh --hard-mode   # seeds DLTDEMO-3 with intentional typo
```

The pipeline will fail on a schema mismatch; `pipeline-runner` reads the error, fixes the typo, retries. Adds ~3 minutes and a strong "agent recovers from real failures" beat.

---

## Repo layout

```
dlt-demo/
├── .claude/skills/jira-to-tdd/    # the reusable skill (project-level)
├── .tdd/                          # TDD ticket backlog/in-progress/completed
│   └── prds/001-tdd-databricks-showcase.md   # the PRD (full design context)
├── databricks/                    # Databricks Asset Bundle
│   ├── databricks.yml             # bundle config (sandbox.dltdemo target)
│   ├── resources/                 # pipeline YAML
│   └── src/
│       ├── pipelines/             # bronze_a / bronze_b / silver_c (stubs)
│       └── seed_data/             # customers.csv, orders.csv
├── scripts/
│   ├── health-check.sh            # 6 preflight checks
│   ├── seed-jira.sh               # provision Jira project + 3 issues
│   ├── reset-demo.sh              # idempotent teardown (<120s)
│   ├── upload-seed-data.sh        # push CSVs to Unity Catalog Volume
│   └── dry-run.sh                 # 5-cycle measurement run for M1/M2/M3
└── docs/
    ├── RUNBOOK.md                 # ← presenter script (read this!)
    └── volume-paths.md            # UC Volume conventions
```

---

## What's being showcased

| Plugin / skill | Where it shines |
|---|---|
| **`ticket-driven-dev`** | `.tdd/` lifecycle, `/ralph-tackle`, parallel dependency-aware execution |
| **`databricks-compass`** | `pipeline-runner` validate→deploy→run→fix loop, bundle-driven dev |
| **`jira-reader` / `jira-writer`** | Underlying Jira REST integration |
| **`jira-to-tdd` (this repo)** | The bridge skill — spawns parallel agents to import a Jira project as a TDD backlog with dependencies preserved |

---

## Workspace details (for the presenter)

- **Databricks workspace:** `https://dbc-34be68e4-80e5.cloud.databricks.com`
- **Profile:** `julien-compass`
- **Catalog / schema:** `sandbox.dltdemo`
- **Pipeline:** `dltdemo_pipeline` (serverless DLT, dev target)
- **Jira project:** `DLTDEMO` at `compassdataanalytics.atlassian.net`

---

## If something breaks during the demo

See `docs/RUNBOOK.md` — every act has explicit fallbacks (auth expired, Jira down, tackle stuck, DLT cold-start, etc.). The two most common:

- **Databricks auth expired** → `databricks auth login --profile julien-compass`, then re-run `health-check.sh`.
- **Jira API hiccup** → `seed-jira.sh` is idempotent; re-run.

---

## Non-goals

This is a **demo**, not a production pipeline. The A/B/C transforms are deliberately simple. The point is the toolchain composition, not the data engineering.
