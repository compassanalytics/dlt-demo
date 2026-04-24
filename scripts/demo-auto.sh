#!/usr/bin/env bash
# scripts/demo-auto.sh — Tier 3 (Auto): one-command end-to-end demo
#
# Drives the full DLT-Demo flow autonomously via `claude --print`. The presenter
# types one command and watches the agent transcript scroll. No prompts, no
# manual gating, no slash commands typed by hand.
#
# Phases:
#   1. Bash preflight: health-check → reset → seed
#   2. Headless Claude: /ingest-jira → /ingest-docs → /build-pipeline → /verify
#   3. Bash assertion: confirm 3 tables exist in sandbox.dltdemo
#
# Usage: bash scripts/demo-auto.sh [--hard-mode] [--no-reset] [--skip-docs] [--transcript-file PATH] [-h|--help]
#
# Required env: JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN
# Required CLI: bash 4+, jq, databricks, claude
#
# Exit codes:
#   0  — DEMO_COMPLETE: SUCCESS
#   1  — preflight failure (don't blame the agent)
#   2  — agent run failed (Claude exited non-zero)
#   3  — final assertion failed (agent thought it succeeded but tables missing)

set -uo pipefail

# ─── Defaults ──────────────────────────────────────────────────────────────
HARD_MODE=0
NO_RESET=0
SKIP_DOCS=0
TRANSCRIPT_FILE=""
DATABRICKS_PROFILE="julien-compass"
SCHEMA_FQN="sandbox.dltdemo"
EXPECTED_TABLES=("bronze_customers" "bronze_orders" "silver_customer_summary")

# ─── Colors ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; BLUE=""; BOLD=""; DIM=""; RESET=""
fi
phase() { printf "\n%s%s%s\n" "$BOLD$BLUE" "═══ $* ═══" "$RESET"; }
ok()    { printf "%s✓%s %s\n" "$GREEN" "$RESET" "$*"; }
warn()  { printf "%s⚠%s %s\n" "$YELLOW" "$RESET" "$*" >&2; }
err()   { printf "%s✗%s %s\n" "$RED" "$RESET" "$*" >&2; }

# ─── Args ──────────────────────────────────────────────────────────────────
show_help() {
  cat <<'EOF'
Usage: demo-auto.sh [OPTIONS]

One-command headless run of the DLT-Demo. Bash drives setup; Claude --print
drives the demo phases; bash asserts the final state.

Options:
  --hard-mode              Seed DLTDEMO-3 with deliberate typo (failure-and-recovery storyline)
  --no-reset               Skip reset-demo.sh (use when state is already clean)
  --skip-docs              Skip /ingest-docs phase (faster, less context-rich)
  --transcript-file PATH   Tee Claude's stdout to PATH for post-run review
  -h, --help               Show this help

Required environment: JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN.
Databricks profile: julien-compass (must be authenticated).

Exit codes: 0 success / 1 preflight fail / 2 agent fail / 3 assertion fail.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hard-mode)        HARD_MODE=1; shift ;;
    --no-reset)         NO_RESET=1; shift ;;
    --skip-docs)        SKIP_DOCS=1; shift ;;
    --transcript-file)  TRANSCRIPT_FILE="$2"; shift 2 ;;
    -h|--help)          show_help; exit 0 ;;
    *)                  err "Unknown flag: $1"; show_help; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ─── Phase 1: bash preflight ───────────────────────────────────────────────
phase "Phase 1 / 3 — Preflight (bash)"

T0=$(date +%s)

if ! command -v claude >/dev/null; then
  err "'claude' CLI not found on PATH. Install Claude Code first."
  exit 1
fi
if ! command -v jq >/dev/null; then
  err "'jq' not found on PATH. brew install jq."
  exit 1
fi

if ! bash scripts/health-check.sh; then
  err "Health-check failed. Fix and re-run. Don't blame the agent."
  exit 1
fi
ok "Health-check passed"

if [[ "$NO_RESET" -eq 0 ]]; then
  if ! bash scripts/reset-demo.sh; then
    err "Reset failed. Manual intervention required."
    exit 1
  fi
  ok "Reset complete (clean baseline)"
else
  warn "Skipping reset (per --no-reset). Demo will run against current state."
fi

SEED_FLAG=""
[[ "$HARD_MODE" -eq 1 ]] && SEED_FLAG="--hard-mode"
if ! bash scripts/seed-jira.sh $SEED_FLAG; then
  err "Jira seed failed. Check creds + project permissions."
  exit 1
fi
ok "Jira seeded (hard-mode=$HARD_MODE)"

T1=$(date +%s)
PREFLIGHT_DURATION=$((T1 - T0))
ok "Preflight done in ${PREFLIGHT_DURATION}s"

# ─── Phase 2: headless Claude run ──────────────────────────────────────────
phase "Phase 2 / 3 — Autonomous demo (claude --print)"

# Build the prompt. Each step is one of our /tier-2 slash commands so the
# agent operates through the same surface a human presenter would use.
DOCS_STEP=""
if [[ "$SKIP_DOCS" -eq 0 ]]; then
  DOCS_STEP="2. Run /ingest-docs prd to summarise the PRD into per-ticket Context Briefs at .tdd/notes/context-briefs/."
else
  DOCS_STEP="2. (skipped per --skip-docs)"
fi

HARD_MODE_NOTE=""
if [[ "$HARD_MODE" -eq 1 ]]; then
  HARD_MODE_NOTE="
  HARD MODE is active. DLTDEMO-3 has a deliberate 'customerid' typo. When the
  silver_c.py tackle session deploys and fails with a schema mismatch, narrate
  the failure briefly, then have the tackle session fix the typo to 'customer_id'
  and redeploy. The recovery is the demo, not a bug — do not abort."
fi

PROMPT=$(cat <<EOF
You are running the DLT-Demo autonomously. No human will type anything between
now and completion. Do not pause to ask for confirmation. If a step fails,
attempt one recovery; if that fails too, print 'DEMO_COMPLETE: FAILURE' with
a one-line cause and stop.
${HARD_MODE_NOTE}

Execute these four steps in order:

1. Run /ingest-jira DLTDEMO. Confirm 3 TDD tickets land in .tdd/backlog/ with
   the diamond dependency wired (#003 blocked by #001, #002).

${DOCS_STEP}

3. Run /build-pipeline. This invokes /ralph-tackle which spawns parallel tackle
   sessions. Monitor progress via the ticket-driven-dev MCP tools (ticket_list,
   tmux peek). When all 3 tickets reach completed state, proceed.

4. Run /verify. Confirm bronze_customers, bronze_orders, and
   silver_customer_summary exist in sandbox.dltdemo with non-zero row counts.

When all four steps succeed, print exactly: 'DEMO_COMPLETE: SUCCESS' on its own
line. That sentinel is how the calling bash script knows you finished.
EOF
)

CLAUDE_LOG="${TRANSCRIPT_FILE:-$REPO_ROOT/artifacts/demo-auto-$(date -u +%Y%m%dT%H%M%SZ).log}"
mkdir -p "$(dirname "$CLAUDE_LOG")"

ok "Transcript will be written to: $CLAUDE_LOG"

T2=$(date +%s)
set +e
claude --print \
  --permission-mode acceptEdits \
  --output-format text \
  --add-dir "$REPO_ROOT" \
  "$PROMPT" 2>&1 | tee "$CLAUDE_LOG"
CLAUDE_EXIT=${PIPESTATUS[0]}
set -e
T3=$(date +%s)
AGENT_DURATION=$((T3 - T2))

if [[ $CLAUDE_EXIT -ne 0 ]]; then
  err "Claude exited non-zero (code=$CLAUDE_EXIT) after ${AGENT_DURATION}s"
  err "Transcript: $CLAUDE_LOG"
  exit 2
fi

if ! grep -q '^DEMO_COMPLETE: SUCCESS' "$CLAUDE_LOG"; then
  err "Agent did not emit 'DEMO_COMPLETE: SUCCESS' sentinel. Treating as failure."
  err "Transcript: $CLAUDE_LOG"
  exit 2
fi
ok "Agent reported success in ${AGENT_DURATION}s"

# ─── Phase 3: bash assertion ───────────────────────────────────────────────
phase "Phase 3 / 3 — Final assertion (bash, independent of agent)"

MISSING=()
TABLE_LIST=$(databricks tables list "$SCHEMA_FQN" --profile "$DATABRICKS_PROFILE" -o json 2>/dev/null || echo "[]")
for tbl in "${EXPECTED_TABLES[@]}"; do
  if echo "$TABLE_LIST" | jq -e --arg n "$tbl" '.[] | select(.name==$n)' >/dev/null 2>&1; then
    ok "Table present: $SCHEMA_FQN.$tbl"
  else
    err "Table MISSING: $SCHEMA_FQN.$tbl"
    MISSING+=("$tbl")
  fi
done

if [[ ${#MISSING[@]} -ne 0 ]]; then
  err "Final assertion failed — agent claimed success but ${#MISSING[@]} table(s) missing."
  exit 3
fi

T4=$(date +%s)
TOTAL_DURATION=$((T4 - T0))

# ─── Summary ────────────────────────────────────────────────────────────────
phase "DEMO_COMPLETE: SUCCESS"

cat <<EOF
${BOLD}Timings${RESET}
  Preflight:  ${PREFLIGHT_DURATION}s
  Agent run:  ${AGENT_DURATION}s
  Total:      ${TOTAL_DURATION}s

${BOLD}Verified${RESET}
  ✓ ${SCHEMA_FQN}.bronze_customers
  ✓ ${SCHEMA_FQN}.bronze_orders
  ✓ ${SCHEMA_FQN}.silver_customer_summary

${BOLD}Transcript${RESET}
  ${CLAUDE_LOG}

${DIM}Suggested next: open the Databricks UI to show the diamond DAG.${RESET}
  https://dbc-34be68e4-80e5.cloud.databricks.com → Lakeflow Pipelines → dltdemo_pipeline
EOF
