---
description: Ingest design context into the TDD tickets — from the local PRD or a Confluence page.
argument-hint: "[prd | confluence <PAGE_ID_OR_URL>]"
---

# /ingest-docs

Audience-facing "Act 1.5" beat: pull design documentation into per-ticket
context briefs so the implementation phase has real intent to work with —
not just a one-line ticket summary.

Two source modes:

| Argument | Source | Use when |
|---|---|---|
| `prd` (default) | `.tdd/prds/001-tdd-databricks-showcase.md` | The fastest path. Always works (no auth). |
| `confluence <PAGE_ID_OR_URL>` | A live Confluence page via `confluence-reader` | You want to show "Claude pulls real design docs from our wiki." Requires Atlassian auth. |

If the user provides no argument, default to `prd`.

## What to do

### Mode 1: PRD (default)

1. Read `.tdd/prds/001-tdd-databricks-showcase.md`.
2. For each ticket file in `.tdd/backlog/`, write a `Context Brief` section
   (3–6 bullets) capturing:
   - The PRD goal(s) this ticket advances.
   - Constraints/non-goals from the PRD that bound this ticket.
   - Specific design decisions from the "Proposed solution" section relevant
     to this ticket.
3. Write briefs to `.tdd/notes/context-briefs/<ticket-number>.md`. Create the
   directory if needed.
4. Print a summary table: ticket → brief path.

### Mode 2: Confluence

1. Use the `confluence-reader` skill to fetch the page identified by the
   argument (page ID, page title, or full URL — the skill handles all three).
2. Distill the page into the same per-ticket Context Briefs as Mode 1, with
   the addition of a `Source:` line citing the Confluence page URL + last-edited date.
3. Write briefs to the same location: `.tdd/notes/context-briefs/<ticket-number>.md`.

## Why this matters for the demo

The Context Briefs become the bridge between the PRD/Confluence narrative and
the per-ticket tackle sessions. When `/build-pipeline` runs, each tackle
session reads its brief first — so the audience sees Claude making decisions
grounded in real design intent, not just guessing from a 3-word summary.

## Guards

- If `.tdd/backlog/` is empty, **stop** and tell the presenter to run
  `/ingest-jira` first. Briefs without tickets to attach to are wasted work.
- If Confluence auth fails, fall back to PRD mode and tell the presenter:
  "Confluence unreachable — using local PRD instead." Don't kill the demo.
- Briefs are markdown, not code. Keep them under ~30 lines each. The audience
  shouldn't have to read a wall of text on screen.
