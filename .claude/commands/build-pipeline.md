---
description: Implement the TDD backlog — parallel tackle sessions for bronze A/B, then silver C.
---

# /build-pipeline

Audience-facing "Act 2 + Act 3" beat: drive the TDD backlog to completion via
the existing `ralph-tackle` orchestrator. The diamond dependency means A and B
run in parallel, C waits for both — that's the visible payoff.

## What to do

1. **Guard:** confirm `.tdd/backlog/` has at least 3 tickets numbered 001–003.
   If not, **stop** and tell the presenter to run `/ingest-jira` first. Do not
   silently skip — a half-loaded backlog wrecks the demo narrative.

2. **Optional but recommended:** if `.tdd/notes/context-briefs/` is empty,
   suggest `/ingest-docs` to the presenter (don't auto-run it — they may have
   skipped it intentionally).

3. **Invoke the orchestrator:**
   ```
   /ralph-tackle
   ```
   This is a `ticket-driven-dev` plugin command. It computes dependency waves
   and spawns tmux panes for parallel ticket sessions.

4. **Narrate the moment for the presenter** before tackle starts running:
   *"A and B have no blockers — they fan out in parallel. Each tackle session
   uses the `databricks-compass` `pipeline-runner` skill: validate the bundle,
   deploy to the workspace, run, read errors, fix code, retry. C unblocks
   automatically once both finish."*

   This is the "nested agentic loop" beat from the PRD — outer TDD loop drives
   inner pipeline-runner loop. Don't bury it; it's the architectural story.

5. **After tackle completes**, verify all 3 tickets are in `.tdd/completed/`
   and tell the presenter the pipeline is built. Suggest `/verify` next.

## Hard-mode awareness

If `seed-jira.sh` was run with `--hard-mode`, DLTDEMO-3 has a deliberate
`customerid` typo. The C tackle session will deploy, fail with a schema
mismatch, read the error, fix the typo to `customer_id`, redeploy, and succeed.
**Narrate this when it happens** — the recovery is the demo, not a bug.

If the auto-recovery doesn't trigger after the first failure, prompt the
session manually:
> "The error says 'customerid' — change it to 'customer_id' in silver_c.py and retry."

## Guards

- Don't bypass `ralph-tackle` and run individual `/tackle <N>` calls unless the
  orchestrator explicitly fails. The parallelism is the visible payoff.
- If a tackle session stalls for more than ~5 minutes without log activity,
  surface it to the presenter and offer to peek at the tmux pane.
