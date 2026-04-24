# All Gotchas

_Generated index of all gotchas across components._

## High

- (1) create-ticket does NOT parse `--number=NNN` as a flag — the only reliable pre-allocation mechanism is the documented `IMPORTANT: Use ticket number NNN (pre-allocated). Do NOT call next_ticket_number.sh.` preamble in the feature-description arg. (2) Project-level skill YAML frontmatter supports ONLY `name` + `description` — `triggers:` and `argument-hint:` are non-standard and silently ignored; embed trigger phrases in description body. (3) `SendMessage(to="type-name")` type-addresses a single teammate — multiple messages serialize; use named teammates via `Agent(name="ct-{key}", team_name=...)` for true parallelism. (4) Idempotency H1 regex must match the normalized form actually written by create-ticket — strip Jira key from spawn title so `# Feature: {summary}` round-trips on re-run. (5) Every create-ticket spawn should include `--quick` when Context Brief is authoritative — otherwise Phase 2F spawns 2-3 codebase-explorer sub-agents each (3 issues → 9-12 concurrent agents, unwatchable). _(_unlinked_)_
- ticket-spec-catalog-drift: Ticket #004 spec used `julien_compass.dltdemo.raw` but ticket #003's DAB scaffold verified the real catalog is `sandbox`. Always cross-check ticket catalog names against the actual `databricks/databricks.yml` bundle variables before implementing — specs written before workspace discovery can outlive their assumptions. _(_unlinked_)_
- ticket-spec-cli-flag-drift: Ticket #004 spec example used `--volume-type MANAGED` as a flag. The real CLI syntax is positional (4th arg). Always `databricks <cmd> --help` before trusting a shell example copied from a spec doc. _(_unlinked_)_
- expired-auth-on-julien-compass: `databricks auth profiles` shows `julien-compass` = `NO`; upload scripts requiring live calls must be tested after `databricks auth login --profile julien-compass`. Scripts should fail loudly (non-zero exit) rather than swallow auth errors — `set -euo pipefail` + explicit `exit 1` on non-"already exists" paths guarantee this. _(_unlinked_)_
- seed-data-location-vs-spec: Spec said `databricks/seed_data/`; actual bundle convention from ticket #003 is `databricks/src/seed_data/`. Source assets live under `databricks/src/` per the bundle layout; non-source stays in `databricks/resources/`. _(_unlinked_)_

_Last updated: 2026-04-22_

