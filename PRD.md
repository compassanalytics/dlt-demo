---
prd: 001
title: TDD + Databricks Compass showcase demo
created: 2026-04-22
status: implementing
owner: @julien.hovan
---

# PRD 001: TDD + Databricks Compass showcase demo

## Problem

Compass has shipped two substantial Claude Code plugins — `ticket-driven-dev` (TDD)
and `databricks-compass` — plus a set of general-purpose skills (jira-reader,
jira-writer, atlassian). Prospective users and our own CTO's pitch audience
cannot currently see these working end-to-end in a single coherent story. Demos
today are either:

- Static (slides, screenshots) — no "oh, it actually does the thing" moment, or
- Live improvisation — fragile, auth-flaky, hard to rehearse, hard to re-run.

We need a repeatable, self-contained demo that proves the plugins work
*together* on a realistic Databricks data-engineering workflow. The demo must
be idempotent — re-runnable back to a clean baseline in under 2 minutes — so
Julien (the engineer) can test freely and anyone can re-perform it without
hunting for hidden state.

## Users

**Primary**: Julien (engineer driving the demo) and the Compass CTO (presents
the demo to external clients and internal audiences).

**Secondary**: Prospective clients evaluating whether Compass's Claude Code
toolchain meaningfully accelerates data-engineering work on Databricks, and
internal team members who want a reference for how the pieces compose.

Today the workaround is hand-waving through screenshots or showing pieces in
isolation — which loses the core narrative that the toolchain's value comes
from the *composition*, not any single plugin.

## Goals

Concrete outcomes that must be true when this ships:

- [ ] **G1 — End-to-end demo runs green.** Starting from an empty `.tdd/`
  backlog and a freshly-seeded Jira project, Claude Code ingests Jira tickets,
  converts them to TDD backlog tickets with dependencies encoded, launches
  them in dependency order, and produces three Unity Catalog tables (A, B, C)
  via a Lakeflow Declarative Pipeline — all without manual intervention past
  the "go" command.
- [ ] **G2 — Idempotent reset under 2 minutes.** A single `./scripts/reset-demo.sh`
  returns Jira issues, `.tdd/backlog/`, the DLT pipeline, and the Unity Catalog
  schema to a known baseline. Re-running the full demo immediately after reset
  produces the same final state.
- [ ] **G3 — The "nested agentic loop" narrative lands.** The demo surfaces
  the recursion clearly: outer loop (TDD: explore→plan→implement→review per
  ticket) drives inner loop (databricks-compass `pipeline-runner`:
  validate→deploy→run→fix→retry per implementation). Tested by a dry-run with
  a non-engineer colleague who can articulate the nesting back after watching.
- [ ] **G4 — Reusable jira→tdd skill extracted.** The Jira-to-TDD bridge ships
  as a standalone skill (`jira-to-tdd`) under
  `~/.claude/skills/` (or plugin-hosted), usable outside this demo by anyone
  with jira-reader access.
- [ ] **G5 — Runbook exists.** `docs/RUNBOOK.md` documents exact demo steps,
  the narrative beats the presenter should hit, and known-failure fallbacks
  (what to do if Databricks auth is expired mid-demo, if Jira rate-limits, etc.).

## Non-goals

- **Not a production data pipeline.** The A/B/C tables exist to demonstrate
  dependency mechanics, not to be useful transformations. SQL/Python stays
  dumb-simple on purpose.
- **Not a Jira-import tool for arbitrary workflows.** The `jira-to-tdd` skill
  handles the shapes this demo needs (issue summary→title, description→acceptance
  criteria, "is blocked by" links→TDD Blocked By). General-purpose issue-type
  mapping, attachment handling, sprint import, etc. are explicitly out.
- **Not fancy presentation.** No slides, no custom UI, no narration recording.
  Julien's boss (the CTO) writes his own pitch; the engineering deliverable is
  the content and the runnable demo.
- **Not multi-workspace.** Targets exactly the `julien-compass` Databricks
  profile and Unity Catalog sandbox. Porting to other workspaces is out of scope.
- **Not a full Compass plugin marketing surface.** This demo showcases TDD +
  databricks-compass + jira-reader/writer. It does not try to cover every
  skill in every plugin.

## Proposed solution

A self-contained project layout inside `DLT-Demo/` that produces a repeatable
live-coding performance when a presenter types a few commands into Claude Code.

**Key architectural decisions:**

1. **Jira project as source of truth for the demo narrative.** The demo story
   "opens" from Jira tickets because that's how real teams receive work. A
   one-time script provisioned via `jira-writer` seeds a `DLTDEMO` project
   with three issues: `Create bronze table A`, `Create bronze table B`,
   `Create silver table C (joins A + B)`. Issue `C` has "is blocked by" links
   to `A` and `B`.

2. **`jira-to-tdd` skill as the bridge and the reusable deliverable.** This is
   the most valuable non-demo artifact. It:
   - **Uses the `jira-reader` skill** (NOT the Atlassian MCP) to fetch issues from a given Jira project.
   - Parses each issue into a Context Brief.
   - Resolves "is blocked by" Jira issue links and maps them to TDD `Blocked By` frontmatter.
   - Spawns parallel `create-ticket` teammates (one per issue), following the
     same pattern `/ralph-pm` uses so it feels native to the existing toolchain.
   - **Hosted as a project-level skill** at `.claude/skills/jira-to-tdd/` inside this repo for now; promotion to a first-class skill in the `ticket-driven-dev` plugin is a follow-up decision after the demo stabilizes.
   - Seeding DLTDEMO Jira issues uses the `jira-writer` skill (also NOT the Atlassian MCP).

3. **Lakeflow Declarative Pipeline (Python) as the Databricks payload.** One
   pipeline, three tables. A and B are streaming tables reading from small
   seed datasets (committed to the repo). C is a materialized view joining
   them. Chosen over SQL because Julien wants to showcase Python DLT
   development iteratively, and over Jobs because DLT renders a DAG that
   visually mirrors the ticket dependency graph — the payoff moment.

4. **`tackle-ticket` per issue uses `pipeline-runner`.** Each ticket's
   implementation phase invokes the databricks-compass `pipeline-runner` skill,
   which handles validate→deploy→run→read-errors→fix loops autonomously. This
   is where the "nested agentic loops" story becomes concrete: the outer TDD
   loop drives the inner Databricks loop.

5. **Single `reset-demo.sh` for idempotency.** Drops Unity Catalog schema
   (CASCADE), destroys the DLT pipeline if it exists, deletes Jira issues in
   the DLTDEMO project (or transitions them back to To-Do if preserving
   history is desirable — configurable), wipes `.tdd/backlog/` +
   `.tdd/completed/`, resets `.tdd/registry.json`. Optional `--snapshot`
   preserves `.tdd/completed/` + pipeline event logs under `artifacts/<ts>/`.

**Repo layout (target):**

```
DLT-Demo/
├── .tdd/
│   ├── prds/001-tdd-databricks-showcase.md  (this file)
│   ├── backlog/                              (populated by jira-to-tdd during demo)
│   └── completed/
├── databricks/
│   ├── databricks.yml                        (DAB bundle config)
│   ├── pipelines/dltdemo_pipeline.py         (the DLT pipeline — iteratively built)
│   └── seed_data/                            (tiny CSVs seeding A, B)
├── scripts/
│   ├── seed-jira.sh                          (create DLTDEMO project + 3 issues via jira-writer)
│   ├── reset-demo.sh                         (full idempotent reset)
│   └── health-check.sh                       (pre-demo diagnostics)
├── .claude/skills/
│   └── jira-to-tdd/                          (project-level skill, SKILL.md format)
└── docs/
    └── RUNBOOK.md                            (exact demo script + fallbacks)
```

**Demo flow (what the presenter types):**

1. `./scripts/health-check.sh` (outside Claude Code, pre-flight)
2. In Claude Code: "Read the DLTDEMO tickets from Jira and convert them into TDD tickets." → triggers jira-reader → `jira-to-tdd` skill → parallel create-ticket agents → dependency graph populated.
3. `/ralph-tackle` (or `tmux spawn` of all three) → A and B run in parallel, C waits until both complete.
4. Each tackle session uses `pipeline-runner` to develop `pipelines/dltdemo_pipeline.py` iteratively.
5. Final state: DLT pipeline in Databricks UI shows A, B, C as a diamond DAG; tables exist in Unity Catalog; all three TDD tickets in `completed/`.

## Success metrics

- **M1 — Reset time**: `./scripts/reset-demo.sh` completes in under 120s on a warm connection (measured: wall clock).
- **M2 — End-to-end time**: from "go" command to all three tables created and verified, under 25 minutes (measured: wall clock of a full run).
- **M3 — Re-run reliability**: 5 consecutive full runs (reset → demo) succeed without manual intervention. Flake rate target: 0/5.
- **M4 — Non-engineer comprehension**: at least one non-engineer colleague, after watching once, can correctly explain (a) what TDD does and (b) what databricks-compass does in their own words.
- **M5 — Skill reusability**: `jira-to-tdd` skill successfully ingests a non-demo Jira project (a real Compass project) in a one-shot test — demonstrating it's not narrowly fitted to the demo.

## Risks & open questions

### Risks

- **Databricks auth token expires mid-demo** → Mitigation: `health-check.sh` validates `databricks auth profiles | grep julien-compass | grep YES` before each demo run; runbook has explicit `databricks auth login` recovery step.
- **Jira rate limits or API changes** → Mitigation: jira-writer seed script is idempotent (checks for existing issues before creating); fallback to pre-seeded static JSON snapshot stored in `scripts/jira_fixture.json` that can replace live Jira if the API is down.
- **DLT pipeline cold-start latency** makes the demo feel dead** → Mitigation: pre-warm the pipeline during health-check (run once before the demo, then reset tables but keep the pipeline definition); document expected wait times in runbook so presenter can fill the silence with narrative.
- **`jira-to-tdd` skill's dependency resolution fails on edge cases** (cycles, missing issues, cross-project links) → Mitigation: scope strictly to the demo's 3-issue shape with explicit "is blocked by" links; document known limits in the skill's SKILL.md; add cycle detection + clear error message.
- **Tackle sessions fight over the same file** (all three touch `dltdemo_pipeline.py`) → Mitigation: **design this intentionally.** Option A: each ticket owns one @dlt.table block in separate files (`bronze_a.py`, `bronze_b.py`, `silver_c.py`) imported by the main pipeline module — no conflict. Option B: serialize C explicitly (blocked-by ensures it runs last; A and B parallel but edit different files). Going with Option A — clean separation + lets us showcase parallel work without a coordination problem.
- **Unity Catalog permissions** on the sandbox might not allow pipeline creation by Julien's principal → Mitigation: verify during the very first ticket's exploration phase; if blocked, switch to a user-scoped schema Julien definitely owns.

### Open questions (all resolved)

- [x] Demo timeline — resolved: no hard deadline, build for quality.
- [x] Jira workspace — resolved: create fresh `DLTDEMO` project via jira-writer skill.
- [x] Repo location — resolved: build inside `DLT-Demo/`.
- [x] jira→tdd as reusable skill — resolved: yes.
- [x] Pipeline language — resolved: Python DLT.
- [x] Cleanup strategy — resolved: idempotent reset with optional --snapshot.
- [x] **Seed data shape** — resolved: A = `customers.csv` (id, name, region, signup_date), B = `orders.csv` (order_id, customer_id, amount, order_date), C = customer-level order rollup joining them.
- [x] **Jira issue reset strategy** — resolved: delete + recreate (cleaner baseline, matches idempotency goal).
- [x] **jira-to-tdd skill hosting** — resolved: project-level skill inside this repo (`.claude/skills/jira-to-tdd/`) for now; promote to first-class skill in `ticket-driven-dev` plugin after the demo stabilizes.
- [x] **"Watch it fail and recover" demo mode** — resolved: yes, implement as optional `--hard-mode` flag on seed-jira.sh. Default seeds happy-path tickets; hard mode seeds a ticket with an intentional typo/schema mismatch so the demo can showcase pipeline-runner's fix-and-retry loop visibly.

### Hard constraint (from user feedback)

**Never use the `claude.ai Atlassian` MCP (`mcp__claude_ai_Atlassian__*`) for any Jira operation in this project.** All Jira interaction goes through the `jira-reader`, `jira-writer`, and `atlassian` skills. This is durable project guidance, not a preference of convenience.

## Tickets

Each row becomes a backlog ticket via a parallel `create-ticket` agent spawn.

**Framing:** Engineering tickets in this PRD build the *scaffolding* that makes
the demo possible. The three A/B/C implementation tickets are **NOT** in this
list — they are the ones the audience watches get created dynamically during
the demo, via `jira-to-tdd`, from Jira issues. Our scaffolding leaves the DLT
pipeline in a state where it validates and runs but produces *empty tables*;
demo-time tackle sessions flesh out `bronze_a.py`, `bronze_b.py`, `silver_c.py`
into real transforms. That's the payoff moment.

| # | Ticket title | Complexity | Depends on | Ticket number |
|---|---|---|---|---|
| 1 | Build `jira-to-tdd` project-level skill (reads Jira issues via jira-reader, resolves blocked-by links, spawns parallel create-ticket agents) | Medium | — | **#001** |
| 2 | Build `scripts/seed-jira.sh` — provision DLTDEMO Jira project + 3 linked issues via jira-writer skill, with optional `--hard-mode` for intentional-failure demo | Medium | — | **#002** |
| 3 | Scaffold Databricks Asset Bundle (`databricks/databricks.yml`, targets for `julien-compass` sandbox catalog) | Low | — | **#003** |
| 4 | Scaffold DLT pipeline module structure with **stub** `bronze_a.py` / `bronze_b.py` / `silver_c.py` (pipeline validates, tables exist but are empty) + main pipeline entrypoint | Medium | #003 | **#005** |
| 5 | Commit seed data (`customers.csv`, `orders.csv`) to repo + Volume upload logic with defined schemas | Low | #003 | **#004** |
| 6 | Build `scripts/reset-demo.sh` — idempotent teardown (Databricks + Jira + .tdd/) with optional `--snapshot` | Medium | #002, #003 | **#009** |
| 7 | Build `scripts/health-check.sh` — pre-demo diagnostics (databricks auth, jira connectivity, DLT pipeline state, sandbox catalog accessible) | Low | #009 | **#006** |
| 8 | Write `docs/RUNBOOK.md` — presenter script (beat-by-beat narrative), known-failure fallbacks, timing expectations | Low | #001–#006, #009 | **#007** |
| 9 | End-to-end dry-run — full reset → demo → measurements for M1/M2/M3, fix any flakes discovered | Medium | all others | **#008** |

### Execution waves (from dependency-analyzer)

- **Wave 1** (no deps, parallel): #001, #002, #003
- **Wave 2** (after Wave 1): #004, #005, #009
- **Wave 3** (after Wave 2): #006
- **Wave 4** (after Wave 3): #007
- **Wave 5** (after Wave 4): #008

Critical path: #003 → #009 → #006 → #007 → #008 (5 waves deep).

This gives 9 engineering tickets, not 10. The deleted "implement A/B/C" rows were
removed because they confuse the build-vs-demo boundary — those implementations
are the audience-facing moment, not something we pre-implement.

## Changelog

- 2026-04-22: drafted with @julien.hovan during /ralph-pm session. Scope, non-goals, and proposed solution aligned. 4 open questions remain.
- 2026-04-22: all open questions resolved; skill hosting scoped to project-level under `.claude/skills/jira-to-tdd/`; hard-mode demo variant approved; hard constraint added re: never using Atlassian MCP. Status → `approved`.
- 2026-04-22: 9 tickets created in `.tdd/backlog/` via parallel create-ticket agents; dependency-analyzer wired `Blocked By` / `Blocks` frontmatter and produced `.tdd/DEPENDENCIES.md`. Status → `implementing`.
