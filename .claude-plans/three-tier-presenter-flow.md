# Scoping: Three-Tier Presenter Flow

**Status:** Tier 2 shipped (PR #2 merged); Tier 3 implemented (this PR)
**Author:** julien.hovan + Claude
**Date:** 2026-04-24
**Source ask:** Provide three escalating ways to run the demo — fully manual w/ guide, slash-command-driven, fully autonomous one-shot.

---

## Goal

A single repo that supports three demo modes, each landing the same payoff (diamond DAG in Databricks UI) but at progressively higher levels of agent autonomy:

| Tier | Audience | Effort during demo | Resilience |
|------|----------|---------------------|-----------|
| **T1 — Manual + guided** | Engineers / curious clients who want to *see Claude reason* | Presenter types every prompt; pauses to narrate | High — every step is presenter-paced |
| **T2 — Slash-command driven** | Mixed audiences; the boss running it solo | Presenter types ~3 slash commands sequentially | Medium — each command is a defined unit |
| **T3 — One-command autonomous** | Pitch demos for non-technical clients; "set it and watch it" | Presenter types one command, narrates while it runs | Lowest — any mid-run flake derails the demo |

Each tier should be a **first-class story** (not "lesser modes") — a presenter consciously picks the right tier for the room.

---

## Inventory: what already exists

| Capability | Form | Where |
|---|---|---|
| Health-check, reset, seed | bash scripts | `scripts/health-check.sh`, `scripts/reset-demo.sh`, `scripts/seed-jira.sh` |
| Manual presenter walkthrough | runbook (~255 lines) | `docs/RUNBOOK.md` |
| Jira → TDD bridge | project-level skill | `.claude/skills/jira-to-tdd/` (slash-invocable as `/jira-to-tdd <KEY>`) |
| TDD orchestration | plugin slash commands | `/ralph-tackle`, `/tackle <N>` (from `ticket-driven-dev`) |
| Pipeline build/run loop | plugin skill | `pipeline-runner` (from `databricks-compass`) |
| Confluence reading | plugin skill | `confluence-reader` (general-purpose, available globally) |
| 5-cycle measurement runner | bash + manual gating | `scripts/dry-run.sh` (bash drives setup; pauses for human to type slash commands) |

**Not present yet:**
- `.claude/commands/` directory — no project-level slash commands authored
- Any "ingest documentation" capability wired into the demo narrative
- A truly autonomous one-shot entrypoint (`dry-run.sh` is hybrid, not autonomous)

---

## Tier-by-tier scope

### T1 — Manual + guided (≈80% there)

**What it is:** Presenter types each prompt verbatim from a guide. The agent reasons visibly. No project-level slash commands required — uses native skill invocation through natural language and `/jira-to-tdd`.

**What exists:** `docs/RUNBOOK.md` already covers Acts 1–3 + Payoff with timing, audience-cues, and fallbacks.

**Gaps to close:**
1. **`docs/MANUAL_MODE.md`** (new, ~80 lines) — a single-page presenter card distilling RUNBOOK to "the prompts you literally type, in order." Deliberately short so the presenter can hold it on a second monitor.
2. **Add a "documentation ingest" beat** — currently absent from the runbook. Options:
   - (a) Have presenter say *"Read the PRD and summarize the goals before tackling tickets."* → showcases reading local docs.
   - (b) Pull a Compass Confluence page (e.g., DLT design notes) via `confluence-reader` and use it as ticket context. Stronger story but adds Confluence-auth dependency.
   - **Recommendation:** start with (a) — local PRD ingest. Cheaper, no new auth. Promote to (b) only if Confluence becomes a stable demo asset.
3. **Audit RUNBOOK against the as-built repo** — pipeline names, file paths, Databricks UI URL all need a quick sanity sweep. Some references may have drifted.

**Deliverable:** `docs/MANUAL_MODE.md` + RUNBOOK refresh PR.

**Effort:** ~half a day. Mostly writing, no agent work.

---

### T2 — Slash-command driven (the new middle tier)

**What it is:** A short, opinionated set of project-level slash commands stored in `.claude/commands/`. Presenter types `/demo-init`, `/ingest-jira`, `/ingest-docs`, `/build-pipeline`, `/verify` in sequence. Each is a thin wrapper that delegates to the existing skills + scripts.

**Why this tier matters:** removes the "what do I type next?" cognitive load while still giving the audience visible *steps*. This is the sweet spot for a non-author presenter (the boss).

**Proposed command surface (5 commands):**

| Command | Wraps | Audience reads |
|---|---|---|
| `/demo-init` | `bash scripts/health-check.sh` + `bash scripts/seed-jira.sh` | "Six checks pass. Three Jira issues seeded." |
| `/ingest-jira` | `/jira-to-tdd DLTDEMO` (existing skill) | "3 issues → 3 TDD tickets, dependencies wired." |
| `/ingest-docs` | Read `.tdd/prds/001-tdd-databricks-showcase.md` + summarize as TDD context, OR Confluence page if (b) chosen | "PRD digested into per-ticket Context Briefs." |
| `/build-pipeline` | `/ralph-tackle` (existing) | Two parallel tackle sessions, then C unblocks. |
| `/verify` | Bash that queries `sandbox.dltdemo.silver_customer_summary` and prints row count + sample | "10 rows in silver table, DAG green." |

**Gaps to close:**
1. **Author 5 markdown files in `.claude/commands/`.** Each is short (frontmatter + 1–2 paragraph instructions for the agent). The slash command system in Claude Code reads these natively — no plumbing required. Reference: `~/.claude/plugins/cache/claude-plugins-official/ralph-loop/1.0.0/commands/ralph-loop.md` as a template.
2. **Decide `/ingest-docs` semantics.** This is the only command without a clean existing analog. Recommend it ingest the PRD + a designated `docs/` page and write per-ticket Context Briefs to `.tdd/notes/`. That gives the audience a visible artifact ("look — Claude wrote a brief for each ticket").
3. **Sequencing safety net.** `/build-pipeline` should refuse to run if `.tdd/backlog/` is empty (i.e., `/ingest-jira` was skipped). One line of guard logic in the slash command body.
4. **Update RUNBOOK** with a "T2 path" sidebar so the presenter sees both the verbose (T1) and slash (T2) prompts in one place.

**Deliverable:** `.claude/commands/{demo-init,ingest-jira,ingest-docs,build-pipeline,verify}.md` + RUNBOOK update.

**Effort:** ~1 day. Mostly authoring. Real risk is `/ingest-docs` design — that's where 80% of the time goes.

**Tradeoff to flag:** slash commands in `.claude/commands/` are **invocation-only macros** — they prepend a prompt to the conversation, they don't execute autonomously. So `/build-pipeline` still requires the presenter to wait while the agent runs. That's fine for T2 (it's *meant* to be paced) but matters for the T3 design below.

---

### T3 — One-command autonomous (the "wow" tier)

**What it is:** Presenter types **one** command in their terminal (not in Claude Code interactively), grabs coffee, comes back to a green DAG. The audience sees Claude's transcript scrolling on screen.

**Architectural question (decision needed):** how does T3 actually drive Claude end-to-end without a human in the loop?

Two real options:

**Option A — `claude --print` headless invocation (recommended)**

A bash script (e.g., `scripts/demo-auto.sh`) does:
```bash
bash scripts/health-check.sh
bash scripts/reset-demo.sh
bash scripts/seed-jira.sh
claude --print --permission-mode acceptEdits --output-format stream-json \
  "Run the full DLT demo. Steps: (1) /jira-to-tdd DLTDEMO, (2) ingest the PRD, (3) /ralph-tackle, (4) verify all 3 tables exist in sandbox.dltdemo and print row counts."
bash scripts/verify-tables.sh   # final assertion
```
- **Pros:** uses native Claude Code CLI; no SDK learning curve; transcript can be piped to a side terminal for the audience; sandbox/permission policies still enforce safety.
- **Cons:** `--permission-mode acceptEdits` means Claude can't ask for confirmation — every tool call must be pre-allowlisted. Need to pre-stage `.claude/settings.json` with the right Bash and MCP permissions.
- **Risk:** any unexpected permission prompt mid-run kills the autonomy story. Requires a careful settings audit.

**Option B — Claude Agent SDK script**

A Python/TS program using the Agent SDK orchestrates each step, invokes the same skills, and ships its own progress UI.
- **Pros:** stronger control over recovery, retry, telemetry. Could even render a custom audience-facing terminal.
- **Cons:** new dependency surface; SDK skill is a separate learning curve; another thing to maintain.

**Recommendation:** start with **Option A**. The Agent SDK is overkill for a demo whose value is the *visible* agent loop. If A turns out to be too brittle in dry-runs, escalate to B.

**Gaps to close (assuming Option A):**
1. **`scripts/demo-auto.sh`** wrapping health-check → reset → seed → `claude --print` → verify.
2. **Pre-allowlist tool permissions** in `.claude/settings.json` so the headless run doesn't stall on prompts. Specifically: Bash patterns for `databricks bundle *`, `databricks tables *`, MCP tools used by `pipeline-runner` and TDD plugins.
3. **Hardening** — health-check failure aborts before the headless invocation; partial-run cleanup if Claude exits non-zero.
4. **A presenter-facing readout** — colorize the transcript or pipe through `jq` so the audience sees structured progress, not a wall of JSON.
5. **Test against `--hard-mode`** — the failure-and-recovery story has to survive autonomous execution to be a credible T3 demo.

**Deliverable:** `scripts/demo-auto.sh` + permission allowlist patch + transcript-formatter.

**Effort:** ~2 days, most of it spent debugging permission prompts and transcript formatting in dry runs.

**Honest risk:** T3 is the showpiece but also the most fragile. Tier 8's #008 dry-run already revealed one flake (the project-creation 403 we just hit); T3 will surface more. Don't promise T3 to clients before 3 consecutive green runs.

---

## Cross-cutting concerns

### Reset / state hygiene

All three tiers must compose with `scripts/reset-demo.sh`. Every tier's "first command" should leave the system in a known clean state so the *next* tier's run starts identically. Currently `reset-demo.sh` exists; just need each tier's entrypoint to call it (or document that `/demo-init` already does).

### `--hard-mode` parity

Hard-mode (intentional failure + recovery) needs to work in all three tiers. Currently it's only manual. T2 needs `/demo-init --hard-mode` or a separate `/demo-init-hard` command. T3 needs an `--hard-mode` flag on `demo-auto.sh`. Easy to bolt on once the happy path works.

### Documentation surface

Three tiers means three entry points in `README.md`:
- "Want to see how Claude reasons?" → T1
- "Want to run it solo with a few keystrokes?" → T2
- "Want a one-command pitch demo?" → T3

This is a meaningful README expansion (≈30 lines added). Should be one of the last steps to reflect what actually shipped.

### Compatibility with existing #008 dry-run

`scripts/dry-run.sh` currently sits awkwardly between T2 and T3 — bash-driven outer loop with a manual Claude phase in the middle. Once T3 lands, `dry-run.sh` should call `demo-auto.sh` per cycle instead of `wait_for_user`. That refactor closes #008 cleanly.

---

## Phased recommendation

**Phase 1 — T2 first (highest leverage, lowest risk)**
- Author 5 slash commands in `.claude/commands/`.
- Sketch `/ingest-docs` with local PRD ingest (no Confluence dep yet).
- Update RUNBOOK with T2 path.
- *Outcome:* the boss can run the demo end-to-end with 5 keystrokes by next week.

**Phase 2 — T1 polish**
- Trim RUNBOOK into `MANUAL_MODE.md` presenter card.
- Add the documentation-ingest beat to T1.
- *Outcome:* presenter resilience for live audiences.

**Phase 3 — T3 with permission audit**
- Author `demo-auto.sh`.
- Audit and tighten `.claude/settings.json` allowlist.
- 3 consecutive green dry-runs before declaring T3 ready.
- *Outcome:* one-command pitch demo for the CTO's external talks.

**Phase 4 — collapse `dry-run.sh` onto `demo-auto.sh`**
- Closes ticket #008.

---

## Open questions for the user

1. **`/ingest-docs` source-of-truth** — local PRD only (cheap), or live Confluence page (richer story, more setup)?
2. **T3 permission posture** — comfortable with `acceptEdits` mode for autonomous runs (Claude can edit/run any pre-allowlisted command without prompting)? Alternative is `bypassPermissions` for a known sandbox, but that requires `--allow-dangerously-skip-permissions`.
3. **Tier naming** — currently calling them T1/T2/T3 internally. For audience-facing materials, prefer something like *"Walkthrough / Guided / Auto"*? *"Manual / Macro / Autonomous"*? Want this nailed before writing READMEs.
4. **Should T2 commands be promoted to a plugin** instead of project-local? Plugin gives them to other Compass projects; project-local keeps the demo self-contained. Project-local is the right starting point; plugin promotion is a follow-up after the demo stabilizes (mirrors the `jira-to-tdd` decision in the PRD).

---

## What I'm NOT proposing in this scope

- A custom UI / web dashboard for the demo. Terminal + Databricks UI is enough.
- Full SDK-based orchestrator (Option B above). Only if A fails.
- A general-purpose "demo framework" that supports multiple repos. This is one repo, one demo.
- Promoting the T2 slash commands to the `databricks-compass` plugin. After demo stabilizes, not before.
