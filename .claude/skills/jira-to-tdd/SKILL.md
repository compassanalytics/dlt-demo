---
name: jira-to-tdd
description: |
  Convert all issues from a Jira project into TDD backlog tickets with dependency
  wiring. Use when the user says "import jira tickets", "convert jira to TDD",
  "read DLTDEMO from Jira", "pull jira issues as tickets", "turn these Jira
  tickets into a backlog", or invokes `/jira-to-tdd` with a project key argument.
  Fetches issues via Jira REST API (jira-reader pattern, env-var auth), resolves
  "is blocked by" links, detects dependency cycles, builds a per-issue Context
  Brief, then spawns parallel `ticket-driven-dev:create-ticket` agents with
  pre-allocated TDD numbers so `blocked_by` wires atomically at creation.
---

# jira-to-tdd

A project-level skill that ingests a whole Jira project into the `.tdd/backlog/`
and wires dependencies (`blocked_by`) from Jira "is blocked by" links.

This is the demo's "oh" moment — three Jira tickets become a fully-wired TDD
dependency graph in one command. Every line of output must be legible to a live
audience.

**Hard constraint**: Do NOT use any `mcp__claude_ai_Atlassian__*` tool. This
skill uses `jira-reader` REST patterns only. Using the Atlassian MCP violates
the project's Jira skills-over-MCP rule and will be rejected.

---

## §1 — Invocation & Argument Parsing

**Slash form**: `/jira-to-tdd DLTDEMO` → `PROJECT_KEY=DLTDEMO`.

**Natural-language form**: "Read DLTDEMO tickets from Jira and make TDD tickets",
"Import my Jira project DLTDEMO", "Convert JIRA project DLTDEMO to TDD tickets".
Extract the project key with this algorithm:

1. Match all tokens in the user's message matching `/\b[A-Z]{2,}[0-9]*\b/`.
2. Filter out stop-list: `JIRA, TDD, API, FROM, READ, CREATE, ADD, THE, AND,
   PROJECT, KEY, FOR, GET, SHOW, IS, IT, MY, TO, OF, IN, WITH, ALL`.
3. If exactly one token remains → that is `PROJECT_KEY`.
4. If zero tokens remain OR more than one token remains → ASK the user:
   "Which Jira project key should I import? (e.g. DLTDEMO)". Wait for reply;
   do not guess.

Store `PROJECT_KEY` for every subsequent step.

---

## §2 — Environment Preflight

Run before any API call:

```bash
if [ -z "${JIRA_DOMAIN:-}" ]; then
  echo "ERROR: JIRA_DOMAIN is not set. Run: source .env  (or export it in ~/.zshrc)"
  exit 1
fi
if [ -z "${JIRA_EMAIL:-}" ]; then
  echo "ERROR: JIRA_EMAIL is not set. Run: source .env"
  exit 1
fi
if [ -z "${JIRA_API_TOKEN:-}" ]; then
  echo "ERROR: JIRA_API_TOKEN is not set. Run: source .env"
  exit 1
fi
echo "✓ Environment verified (JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN)"
```

**Domain normalization** — always reuse `$DOMAIN` from this point on:

```bash
DOMAIN="${JIRA_DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%/}"
```

Name the missing variable explicitly. Do NOT proceed silently. Do NOT fall back
to any Atlassian MCP tool.

---

## §3 — Fetch All Project Issues

Print: `Fetching issues from ${PROJECT_KEY}...` (the count is logged after the
first page arrives via `Fetching ${N} issues from ${PROJECT_KEY}... (page 1)`).

Use paginated POST to `/rest/api/3/search/jql`. The `issuelinks` field MUST be
listed explicitly — it is NOT included in jira-reader's default field list.

```bash
START_AT=0
MAX=50
ALL_ISSUES_JSON="[]"

while : ; do
  RESP=$(curl -s -X POST \
    "https://$DOMAIN/rest/api/3/search/jql" \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{
      \"jql\": \"project = ${PROJECT_KEY} ORDER BY created ASC\",
      \"maxResults\": ${MAX},
      \"startAt\": ${START_AT},
      \"fields\": [\"summary\", \"description\", \"issuetype\", \"status\", \"issuelinks\", \"created\"]
    }")

  # Check for error responses
  ERROR=$(echo "$RESP" | jq -r '.errorMessages[0] // .message // empty' 2>/dev/null)
  if [ -n "$ERROR" ]; then
    case "$ERROR" in
      *"Unauthorized"*|*"unauthorized"*)
        echo "ERROR: Authentication failed (401). Check JIRA_EMAIL and JIRA_API_TOKEN." ;;
      *"403"*|*"forbidden"*|*"Forbidden"*)
        echo "ERROR: No permission to access project ${PROJECT_KEY} (403)." ;;
      *"does not exist"*|*"No project"*)
        echo "ERROR: Project ${PROJECT_KEY} not found." ;;
      *)
        echo "ERROR: Jira API error — $ERROR" ;;
    esac
    exit 1
  fi

  PAGE=$(echo "$RESP" | jq '.issues // []')
  COUNT=$(echo "$PAGE" | jq 'length')
  ALL_ISSUES_JSON=$(echo "$ALL_ISSUES_JSON $PAGE" | jq -s 'add')

  TOTAL=$(echo "$RESP" | jq '.total // 0')
  START_AT=$((START_AT + COUNT))
  [ "$COUNT" -eq 0 ] && break
  [ "$START_AT" -ge "$TOTAL" ] && break
done

N_ISSUES=$(echo "$ALL_ISSUES_JSON" | jq 'length')
echo "✓ Fetched ${N_ISSUES} issues from ${PROJECT_KEY}."
```

**Rate limiting (HTTP 429)**: if a `curl` response body contains `"Too Many
Requests"` or HTTP status 429, print `[WARN] Jira rate limit hit — waiting 5s
before retry...` and `sleep 5`, then retry once. If a second 429 occurs, abort
with a clear error.

**Empty project**: if `N_ISSUES == 0`, print
`No issues found in ${PROJECT_KEY}. Nothing to do.` and exit 0.

---

## §4 — ADF Description Parsing

Jira `description` is Atlassian Document Format JSON. Recursively extract text.
Implementation uses `jq` (available by default on macOS/Linux).

Algorithm (pseudocode — implement inline with `jq` or a short python one-liner):

```
function adf_to_text(node):
  if node is null or node.type is null: return ""
  if node.content is null or empty: return node.text or ""

  parts = []
  for child in node.content:
    switch child.type:
      case "paragraph":
        parts.append(join(" ", [adf_to_text(g) for g in child.content]))
      case "heading":
        level = child.attrs.level or 2
        parts.append("#" * level + " " + join(" ", [adf_to_text(g) for g in child.content]))
      case "text":
        parts.append(child.text or "")
      case "bulletList":
        for item in child.content:
          parts.append("- " + adf_to_text(item))
      case "orderedList":
        for i, item in enumerate(child.content, 1):
          parts.append(str(i) + ". " + adf_to_text(item))
      case "codeBlock":
        lang = child.attrs.language or ""
        body = join("\n", [g.text for g in child.content if g.type == "text"])
        parts.append("```" + lang + "\n" + body + "\n```")
      case "mention":
        parts.append("@" + (child.attrs.text or "mention"))
      case "hardBreak":
        parts.append("\n")
      case "rule":
        parts.append("---")
      case "blockquote":
        inner = join("\n", [adf_to_text(g) for g in child.content])
        parts.append("> " + inner.replace("\n", "\n> "))
      default:   # unknown node type — S5 fallback
        if child.content is present:
          parts.append(adf_to_text(child))
        elif child.text is present:
          parts.append(child.text)
        # else: silently drop
  return join("\n", parts)
```

The **default branch** is non-negotiable: tables, inlineCard, emoji, and any
future node type must degrade gracefully. Crashing mid-import during a live
demo is unacceptable.

If the resulting string is empty, use the literal placeholder
`(No description provided in Jira.)` when building the Context Brief.

---

## §5 — Link Graph Construction

Jira `issuelinks[]` has this shape (v3 REST API):

```json
{
  "type": {"name": "Blocks", "inward": "is blocked by", "outward": "blocks"},
  "inwardIssue":  {"key": "PROJ-X"},
  "outwardIssue": {"key": "PROJ-Y"}
}
```

**Critical direction rule**: On issue C's own JSON, a link whose
`type.inward == "is blocked by"` AND that carries an `inwardIssue` key means
**C is blocked by `inwardIssue.key`**. The `inwardIssue` is always the blocker
of the current issue. Ignore `outwardIssue` on "blocks" links — same
relationship, wrong direction, would double-count.

Build:

```python
blockers = {}   # "PROJ-1" → ["PROJ-0", ...]
for issue in issues:
  key = issue.key
  blockers[key] = []
  for link in issue.fields.issuelinks or []:
    inward_name = link.type.inward or ""
    if inward_name == "is blocked by" and "inwardIssue" in link:
      blocker_key = link.inwardIssue.key
      # Skip cross-project blockers (record later as prose only)
      if blocker_key.startswith(PROJECT_KEY + "-"):
        blockers[key].append(blocker_key)
```

Also collect any cross-project blocker keys into `cross_project_notes[key]` for
inclusion in the Context Brief as prose.

After building: print
`✓ Resolved dependency graph: ${N_EDGES} blocking relationships.`

---

## §6 — Cycle Detection (DFS, Pre-Spawn)

Run BEFORE any ticket creation — after §5 graph is built. Abort with a clear
path on detection; do not create partial tickets.

```
function has_cycle(graph):
  visited = set()
  rec_stack = set()
  parent = {}

  function dfs(node, path_stack):
    visited.add(node)
    rec_stack.add(node)
    for neighbor in graph[node]:
      if neighbor not in visited:
        parent[neighbor] = node
        path_stack.append(neighbor)
        if dfs(neighbor, path_stack): return True
        path_stack.pop()
      elif neighbor in rec_stack:
        # cycle: walk parent chain from node back to neighbor
        cycle = [neighbor]
        cur = node
        while cur != neighbor:
          cycle.append(cur)
          cur = parent.get(cur, neighbor)
        cycle.append(neighbor)
        cycle.reverse()
        print("✗ ERROR: Dependency cycle detected:")
        print("   " + " → ".join(cycle))
        print("   Fix the cycle in Jira, then re-run. No TDD tickets were created.")
        return True
    rec_stack.remove(node)
    return False

  for node in graph.keys():
    if node not in visited:
      if dfs(node, [node]): return True
  return False

if has_cycle(blockers): exit 1
print "✓ No dependency cycles detected."
```

**Non-existent blocker reference** (`blocker_key` not in `issues`): warn and
continue, do not abort:
`[WARN] ${key} references blocker ${blocker_key}, not found in ${PROJECT_KEY}.
Recording as prose note only — no TDD blocked_by entry.`

---

## §7 — Idempotency Scan

Glob `.tdd/backlog/*.md`. For each file, read only the first few lines to
extract the H1 title. TDD tickets use `# {Category}: {Title}` as the H1 —
there is no frontmatter `title` field.

```python
import re, glob, os
existing_titles = {}   # normalized_title → filename

for path in sorted(glob.glob(".tdd/backlog/*.md")):
  with open(path) as f:
    for line in f:
      m = re.match(r"^#\s+\w+:\s+(.+?)\s*$", line)
      if m:
        title = m.group(1).strip().lower()
        existing_titles[title] = os.path.basename(path)
        break

to_create, to_skip = [], []
for issue in issues:
  norm = issue.fields.summary.strip().lower()
  if norm in existing_titles:
    to_skip.append((issue, existing_titles[norm]))
  else:
    to_create.append(issue)

for (issue, filename) in to_skip:
  print(f"[SKIP] {issue.key} — ticket already exists as {filename}")

print(f"→ {len(to_create)} to create, {len(to_skip)} already exist.")
```

Comparison uses `issue.fields.summary` (NO Jira key prefix) because §9 passes
the raw `summary` to create-ticket — so existing `# Feature: {summary}` headers
match cleanly on re-run.

If `to_create` is empty: print the completion table (§13) with zero
created and exit 0. No TeamCreate call.

---

## §8 — Pre-Allocate TDD Numbers (Topological Sort)

Read `.tdd/registry.json` `next_number` (read-only — create-ticket writes it).

```python
import json
with open(".tdd/registry.json") as f:
  next_number = json.load(f)["next_number"]
```

Topological sort (Kahn's) over the `to_create` subset only, with an explicit
tie-break by Jira `created` timestamp ASC inside each level:

```python
create_keys = {issue.key for issue in to_create}
in_degree = {k: 0 for k in create_keys}
adj = {k: [] for k in create_keys}

for k in create_keys:
  for b in blockers.get(k, []):
    if b in create_keys:
      in_degree[k] += 1
      adj[b].append(k)

# Map key → created timestamp for tie-break
created_ts = {i.key: i.fields.created for i in to_create}

topo_order = []
# Current level = all keys with in_degree == 0, sorted by created ASC
while in_degree:
  level = [k for k, d in in_degree.items() if d == 0]
  if not level:
    # unreachable if cycle check passed
    break
  level.sort(key=lambda k: (created_ts[k], k))
  for k in level:
    topo_order.append(k)
    del in_degree[k]
    for neighbor in adj[k]:
      if neighbor in in_degree:
        in_degree[neighbor] -= 1

# Assign zero-padded numbers
number_map = {}   # Jira key → "001", etc.
for i, k in enumerate(topo_order):
  number_map[k] = str(next_number + i).zfill(3)
```

Tie-break is critical for demo legibility — A should become #001, B becomes
#002, C becomes #003 in the typical DLTDEMO scenario.

---

## §9 — Context Brief Construction & Spawn Payload

For each issue in `topo_order`, build the prompt that will be sent to
`ticket-driven-dev:create-ticket`. Use this EXACT shape — do NOT use a
"Variant A" Context Brief label, do NOT use `--number=NNN` as a flag. The
only reliable way to pre-allocate a number is the `IMPORTANT:` preamble.

```
IMPORTANT: Use ticket number {NNN} (pre-allocated). Do NOT call next_ticket_number.sh.
IMPORTANT: Set frontmatter `blocked_by: [{CSV_NNN}]` EXACTLY as listed below.
Do NOT derive blockers from codebase exploration — they are pre-wired from Jira.

{summary} --quick

## Context from Jira (source: {JIRA_KEY})
- **Issue type**: {issuetype.name}
- **Jira status at import**: {status.name}
- **Blocks (TDD numbers)**: {csv of blocked TDD numbers, or "none"}
- **Blocked by (TDD numbers)**: {csv of blocker TDD numbers, or "none"}
- **Cross-project blockers**: {csv of Jira keys outside PROJECT_KEY, or "none"}
- **Design intent (from Jira description)**:
{adf_description or "(No description provided in Jira.)"}

## Notes for create-ticket
- TDD number is pre-allocated as #{NNN}. Do not re-allocate.
- This ticket was imported from Jira. Set `blocked_by` from the list above;
  do not change it during codebase exploration.
- `--quick` flag means skip Phase 2F exploration. This Context is authoritative.
```

Field rules:
- `{summary}` is `issue.fields.summary` — NO Jira key prefix (so idempotency
  matches on re-run).
- `{CSV_NNN}` is a comma-separated list of TDD numbers (e.g. `001, 002`), or
  empty string if no blockers. When empty, the first IMPORTANT line still
  directs `blocked_by: []`.
- `{csv of blocked TDD numbers}`: for each issue B where this issue K appears
  in `blockers[B]`, include `number_map[B]`.

---

## §10 — Parallel Spawn via Named Teammates

Use Agent Teams with NAMED teammates (addressing by type alone serializes):

```
TeamCreate "jira-to-tdd-{PROJECT_KEY}"

# Spawn all create-ticket agents in parallel (single response, multiple Agent calls):
for key in topo_order:
  Agent(
    name="ct-" + key.replace("-","_"),   # e.g. ct-DLTDEMO_1
    team_name="jira-to-tdd-{PROJECT_KEY}",
    subagent_type="ticket-driven-dev:create-ticket",
    description="Create TDD ticket for " + key,
    prompt=<payload from §9>
  )
  print(f"[{i+1}/{N}] Spawning create-ticket for {key}: {summary} → TDD #{number_map[key]}")

# Wait for all confirmations (each teammate sends a completion message).

TeamDelete
```

**Fallback (no TeamCreate available)**: spawn sequentially via plain `Agent()`
calls without `team_name`. Do NOT run parallel Task subagents — sequential
fallback is safer and still demo-legible.

---

## §11 — Defensive Post-Hoc `ticket_update` Pass

After all create-ticket agents confirm, re-assert `blocked_by` frontmatter for
every ticket that had blockers. This is a safety net in case create-ticket's
Phase 2F codebase exploration ignored the pre-wired Constraints.

```
for key in topo_order:
  tdd_num = int(number_map[key])
  blocker_nums = [int(number_map[b]) for b in blockers.get(key, []) if b in number_map]
  if blocker_nums:
    mcp__plugin_ticket-driven-dev_ticket-engine__ticket_update(
      number=tdd_num,
      section="frontmatter",
      content=f'{{"blocked_by": {blocker_nums}}}'
    )
    print(f"   ✓ Re-asserted blocked_by on #{number_map[key]}: {blocker_nums}")
```

If primary pre-wiring worked, this pass is a no-op (frontmatter already
correct). If it didn't, this corrects it. Either way, the final state is
consistent before the completion table prints.

---

## §12 — Progress Output Specification

Every output line is a legible English sentence or a table row. No raw JSON,
no silent pauses longer than ~3 seconds without a status line.

Required output events (in this order):

| Event | Format |
|-------|--------|
| Banner | `╔══ jira-to-tdd: Importing ${PROJECT_KEY} ══╗` |
| Env check | `✓ Environment verified (JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN)` |
| Fetching | `Fetching issues from ${PROJECT_KEY}...` |
| Fetched | `✓ Fetched ${N} issues from ${PROJECT_KEY}.` |
| Graph | `✓ Resolved dependency graph: ${E} blocking relationships.` |
| Cycle OK | `✓ No dependency cycles detected.` |
| Idempotency | `→ ${M} to create, ${K} already exist and will be skipped.` |
| Skip | `[SKIP] ${KEY} — ticket already exists as ${filename}` |
| Spawn | `[${i}/${M}] Spawning create-ticket for ${KEY}: ${summary} → TDD #${NNN}` |
| Re-assert | `   ✓ Re-asserted blocked_by on #${NNN}: ${blocker_nums}` |
| Completion | Completion table (§13) |

---

## §13 — Completion Table

After all re-assertions:

```
╔══ Import Complete ══╗

| Jira Key     | Summary                 | TDD Ticket | Blocked By (TDD) | Status   |
|--------------|-------------------------|------------|------------------|----------|
| DLTDEMO-1    | Create bronze table A   | #001       | —                | Created  |
| DLTDEMO-2    | Create bronze table B   | #002       | —                | Created  |
| DLTDEMO-3    | Create silver table C   | #003       | #001, #002       | Created  |

Total: ${M} created, ${K} skipped.
Next: run `/dependency-analyzer` to validate the dependency graph.
```

The final line is a suggestion only — do NOT auto-invoke `/dependency-analyzer`.
The human is in control at demo time.

---

## §14 — Error Modes Reference

| Error | Detection | Response |
|-------|-----------|----------|
| Missing env var | §2 preflight | Name the missing var; suggest `source .env`; stop before any API call |
| `https://` in JIRA_DOMAIN | Handled by normalization | Strip both `https://` and `http://` in sequence |
| HTTP 401 | §3 `curl` response | "Authentication failed — check JIRA_API_TOKEN"; stop |
| HTTP 403 | §3 | "No access to project ${PROJECT_KEY}"; stop |
| HTTP 404 / no project | §3 | "Project ${PROJECT_KEY} not found"; stop |
| HTTP 429 (rate limit) | §3 | `[WARN] rate limit — waiting 5s`; retry once; second 429 → abort |
| Dependency cycle | §6 DFS | Print cycle path; abort, no tickets created |
| Non-existent blocker | §5/§6 | `[WARN]` + continue; record as cross-project prose |
| Empty ADF description | §4 | Use `(No description provided in Jira.)` |
| Unknown ADF node type | §4 fallback | Recurse into `.content` if present, emit `.text` if present, else drop |
| TeamCreate unavailable | runtime | Fall back to sequential Agent() spawn (no team) |
| create-ticket agent failure | missing confirmation | `[ERROR] ${KEY} failed to create`; continue remaining issues; final table shows "Failed" status |
| Ambiguous NL project key | §1 stop-list filter | Ask user once; do not guess |
| Empty project (0 issues) | §3 | Print `No issues found. Nothing to do.`; exit 0 |

---

## §15 — Notes & Open Questions

**Jira status → TDD status (v1 decision)**: every imported TDD ticket lands in
`backlog` regardless of Jira status. This keeps the demo deterministic and
the TDD lifecycle distinct. A "Done" Jira issue is still created as a TDD
ticket — the presenter may then transition it manually if desired.

**Subtasks, Epics, parent links**: out of scope. Subtasks and Epic children
are treated as standalone issues; the `parent` field is ignored. A demo
project with a flat issue list (DLTDEMO: A, B, C) is the supported shape.

**Partial-success self-healing**: if a run fails mid-spawn (some tickets
created, some not), re-running the skill naturally recovers — §7 idempotency
skips the already-created tickets, §8 pre-allocates from the updated
`next_number`, and the remaining issues get created in a second pass. No
manual cleanup needed.

**`--quick` dependency**: this skill passes `--quick` to every `create-ticket`
invocation to prevent Phase 2F sub-agent explosion (otherwise one create-ticket
call spawns 2-3 codebase-explorer agents, yielding 9-12 concurrent agents for
3 Jira issues — unwatchable during a demo). If `create-ticket` renames or
removes `--quick`, this skill's spawn payload must be updated.

**`IMPORTANT:` preamble dependency**: pre-allocated numbering relies on
`create-ticket` honoring `IMPORTANT: Use ticket number NNN` in the feature
description. §11's defensive post-hoc `ticket_update` pass is the safety net
if this convention changes.

**Promotion path**: when this skill graduates to the `ticket-driven-dev`
plugin, consider exposing a `--numbering={topo|jira-order|none}` flag. The
current implementation hard-codes topological-order numbering.

**Reset-demo contract**: ticket #009 (reset-demo.sh) MUST preserve
`.claude/skills/jira-to-tdd/` when resetting. Reset should delete only
`.tdd/backlog/*.md` and registry state — never the skill itself.

**Skill discovery**: project-level skills in `.claude/skills/<name>/SKILL.md`
are auto-discovered by Claude Code when a session is opened inside the
project root. No registration step in `.claude/settings.json` is required
(verified against the jira-reader user-level skill pattern).

**Atlassian MCP prohibition**: never use `mcp__claude_ai_Atlassian__*` for any
operation this skill performs. This is a hard project-level constraint; the
REST + env-vars pattern is the only approved path.
