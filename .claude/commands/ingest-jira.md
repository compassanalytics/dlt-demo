---
description: Convert the DLTDEMO Jira project into a dependency-wired TDD backlog.
argument-hint: "[PROJECT_KEY=DLTDEMO]"
---

# /ingest-jira

Audience-facing "Act 1" beat: turn three Jira issues into three TDD tickets with
the dependency graph preserved.

## What to do

This is a thin wrapper around the existing `jira-to-tdd` skill. Invoke it with
the project key (default: `DLTDEMO`):

```
/jira-to-tdd DLTDEMO
```

If the user passed an argument (e.g. `/ingest-jira ACME`), use that instead.

## What the audience should see

The `jira-to-tdd` skill already produces an audience-friendly completion table:

```
| Jira Key  | Summary               | TDD Ticket | Blocked By (TDD) | Status  |
|-----------|-----------------------|------------|------------------|---------|
| DLTDEMO-1 | Create bronze table A | #001       | —                | Created |
| DLTDEMO-2 | Create bronze table B | #002       | —                | Created |
| DLTDEMO-3 | Create silver table C | #003       | #001, #002       | Created |
```

After it returns, **briefly narrate the result** for the presenter — one sentence:
"Three Jira issues, three TDD tickets, the diamond dependency wired in `.tdd/backlog/`."

## Guards

- If `.tdd/backlog/` already has tickets numbered 001–003, the skill will detect
  this and either reuse or refuse — don't override its judgment.
- If Jira credentials are missing (`JIRA_*` env vars), surface the error from
  the skill verbatim. Don't try to fix it silently.
