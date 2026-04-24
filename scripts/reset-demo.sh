#!/usr/bin/env bash
# scripts/reset-demo.sh — idempotent teardown of the TDD-Databricks demo
#
# Tears down all per-demo state across three systems so a presenter can run
# back-to-back demos without manual cleanup. Target: <120s end-to-end (M1).
#
#   Phase 0 (optional, --snapshot): archive completed/ + pipeline events
#                                    into artifacts/<timestamp>/
#   Phase 1 (Databricks): stop pipeline update (if running), drop Unity Catalog
#                         schema sandbox.dltdemo CASCADE. Keeps pipeline DEFINITION
#                         alive on purpose — `bundle destroy` + re-deploy adds
#                         60-90s cold-start that breaks the M1 120s budget.
#   Phase 2 (Jira): JQL-list all DLTDEMO issues, DELETE each, then re-seed via
#                   seed-jira.sh. Uses jira-writer REST pattern (hard project
#                   constraint: NO Atlassian MCP).
#   Phase 3 (TDD): wipe .tdd/backlog/*.md + .tdd/completed/*.md, write a valid
#                  empty registry.json (version 3 schema, coupled to engine).
#                  Preserves .tdd/prds/, .tdd/engine/, .tdd/archived/, .claude/.
#
# Idempotency: each phase state-checks first; running on an already-clean system
# succeeds silently. Safe to re-run after Ctrl-C mid-run.
#
# Registry schema is pinned to version 3. If the TDD engine upgrades its schema,
# this script must be updated in tandem.
#
# Usage: bash scripts/reset-demo.sh [--snapshot] [-h|--help]
#
# Requires: bash 4+, curl, jq, databricks CLI (>= v0.292.0, preferably 0.298.0+)
# Env vars (required): JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN
# Env vars (optional): DLTDEMO_PIPELINE_ID (skips pipeline-by-name lookup)

set -uo pipefail

# ─── Script-root resolution ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DATABRICKS_PROFILE="julien-compass"
PIPELINE_NAME_SUBSTR="dltdemo_pipeline"
SCHEMA_FQN="sandbox.dltdemo"
JIRA_PROJECT="DLTDEMO"

# ─── Argument parsing ──────────────────────────────────────────────────────
SNAPSHOT=0

show_help() {
  cat <<'EOF'
Usage: reset-demo.sh [OPTIONS]

Idempotent teardown of the TDD-Databricks demo across Databricks, Jira, and TDD.

Options:
  --snapshot    Before teardown, archive .tdd/completed/*.md and the last
                pipeline event log to artifacts/<ISO-timestamp>/.
  -h, --help    Show this help message.

Required environment variables:
  JIRA_DOMAIN       Atlassian domain, e.g. yourcompany.atlassian.net
  JIRA_EMAIL        Jira account email
  JIRA_API_TOKEN    API token from https://id.atlassian.com/manage-profile/security/api-tokens

Optional environment variables:
  DLTDEMO_PIPELINE_ID   Databricks pipeline ID (skips name-based discovery)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --snapshot)  SNAPSHOT=1 ;;
    -h|--help)   show_help; exit 0 ;;
    *)
      printf "Unknown flag: %s\nRun with --help for usage.\n" "$arg" >&2
      exit 2
      ;;
  esac
done

# ─── Colors (TTY-aware) ────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  RED=$'\033[0;31m'
  DIM=$'\033[2m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  GREEN="" YELLOW="" RED="" DIM="" BOLD="" RESET=""
fi

# ─── Timing ────────────────────────────────────────────────────────────────
START_EPOCH=$(date +%s)

elapsed() {
  local now=$(($(date +%s) - START_EPOCH))
  printf "%02d:%02d" $((now / 60)) $((now % 60))
}

log()  { printf "${DIM}[%s]${RESET} %s\n" "$(elapsed)" "$*"; }
ok()   { printf "${DIM}[%s]${RESET} %s ${GREEN}✓${RESET}\n" "$(elapsed)" "$*"; }
skip() { printf "${DIM}[%s]${RESET} %s ${YELLOW}→${RESET} %s\n" "$(elapsed)" "$1" "${2:-skipped}"; }
warn() { printf "${DIM}[%s]${RESET} %s ${YELLOW}⚠${RESET} %s\n" "$(elapsed)" "$1" "${2:-}" >&2; }
err()  { printf "${DIM}[%s]${RESET} %s ${RED}✗${RESET} %s\n" "$(elapsed)" "$1" "${2:-}" >&2; }

EXIT_CODE=0
FAILED_PHASE=""

fail_phase() {
  EXIT_CODE=1
  FAILED_PHASE="${FAILED_PHASE:+$FAILED_PHASE, }$1"
  err "$1" "${2:-}"
}

# Always print timing summary, even on abort/Ctrl-C.
print_timing() {
  local rc=$?
  local end=$(date +%s)
  local dur=$((end - START_EPOCH))
  printf "\n"
  if [[ $rc -eq 0 && $EXIT_CODE -eq 0 ]]; then
    printf "${BOLD}=== Reset completed in %ds (target: <120s) ===${RESET}\n" "$dur"
  else
    printf "${BOLD}${RED}=== Reset FAILED in %ds — phase: %s ===${RESET}\n" "$dur" "${FAILED_PHASE:-prereq}"
  fi
  if [[ $dur -gt 120 ]]; then
    printf "${YELLOW}WARNING: reset exceeded 120s target (M1 metric)${RESET}\n" >&2
  fi
}
trap print_timing EXIT

printf "${BOLD}=== reset-demo.sh ===${RESET}\n"

# ─── Prerequisites ─────────────────────────────────────────────────────────
log "Checking prerequisites..."

# jq required for pipeline-ID lookup + Jira response parsing.
if ! command -v jq >/dev/null 2>&1; then
  err "prereq" "jq not found on PATH — install via 'brew install jq'"
  exit 1
fi

# curl required for Jira REST.
if ! command -v curl >/dev/null 2>&1; then
  err "prereq" "curl not found on PATH"
  exit 1
fi

# Databricks CLI required.
if ! command -v databricks >/dev/null 2>&1; then
  err "prereq" "databricks CLI not found on PATH"
  exit 1
fi

# Jira env vars must be set up-front before anything irreversible runs.
missing=()
for v in JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN; do
  [[ -z "${!v:-}" ]] && missing+=("$v")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  err "prereq" "missing required env vars: ${missing[*]}"
  exit 1
fi

# Databricks auth: `databricks auth profiles | grep Valid` is unreliable on
# this machine (blocks on hostmetadata fetches; falsely reports Valid: NO for
# profiles that successfully authenticate). The reliable probe is a concrete
# API call via current-user me (ticket #003 gotcha in .tdd/NOTES.md).
if ! databricks current-user me --profile "$DATABRICKS_PROFILE" -o json >/dev/null 2>&1; then
  err "prereq" "databricks profile '$DATABRICKS_PROFILE' not authenticated — run: databricks auth login --profile $DATABRICKS_PROFILE"
  exit 1
fi

DOMAIN="${JIRA_DOMAIN#https://}"; DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN%/}"
JIRA_BASE="https://$DOMAIN"
JIRA_AUTH=(-u "$JIRA_EMAIL:$JIRA_API_TOKEN")

ok "Prerequisites OK"

# ─── Phase 0 — Snapshot (conditional) ──────────────────────────────────────
if [[ $SNAPSHOT -eq 1 ]]; then
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  SNAP_DIR="$REPO_ROOT/artifacts/$TS"
  log "[SNAPSHOT] Archiving to artifacts/$TS/..."
  mkdir -p "$SNAP_DIR"

  shopt -s nullglob
  completed_files=(.tdd/completed/*.md)
  shopt -u nullglob
  if [[ ${#completed_files[@]} -gt 0 ]]; then
    cp "${completed_files[@]}" "$SNAP_DIR/" && ok "[SNAPSHOT] Copied ${#completed_files[@]} completed ticket(s)"
  else
    skip "[SNAPSHOT] Copy completed tickets" "no completed/ tickets"
  fi

  # Pipeline event log — needs pipeline ID; resolved below but we duplicate the
  # lookup here so Phase 1 can also consume it without re-querying.
  PIPELINE_ID=""
  if [[ -n "${DLTDEMO_PIPELINE_ID:-}" ]]; then
    PIPELINE_ID="$DLTDEMO_PIPELINE_ID"
  else
    PIPELINE_ID=$(databricks pipelines list-pipelines --profile "$DATABRICKS_PROFILE" -o json 2>/dev/null \
      | jq -r --arg n "$PIPELINE_NAME_SUBSTR" '.[] | select(.name | contains($n)) | .pipeline_id' \
      | head -1)
  fi
  if [[ -n "$PIPELINE_ID" ]]; then
    if databricks pipelines list-pipeline-events "$PIPELINE_ID" --profile "$DATABRICKS_PROFILE" -o json \
        > "$SNAP_DIR/pipeline-events.json" 2>/dev/null; then
      ok "[SNAPSHOT] Saved pipeline-events.json"
    else
      warn "[SNAPSHOT] pipeline events" "could not fetch events for $PIPELINE_ID"
      rm -f "$SNAP_DIR/pipeline-events.json"
    fi
  else
    skip "[SNAPSHOT] Pipeline events" "no pipeline named *${PIPELINE_NAME_SUBSTR}* found"
  fi
fi

# ─── Phase 1 — Databricks teardown ─────────────────────────────────────────
log "[Phase 1] Databricks teardown..."

# Pipeline ID resolution (idempotent — empty PIPELINE_ID means nothing to stop).
if [[ -z "${PIPELINE_ID:-}" ]]; then
  if [[ -n "${DLTDEMO_PIPELINE_ID:-}" ]]; then
    PIPELINE_ID="$DLTDEMO_PIPELINE_ID"
  else
    PIPELINE_ID=$(databricks pipelines list-pipelines --profile "$DATABRICKS_PROFILE" -o json 2>/dev/null \
      | jq -r --arg n "$PIPELINE_NAME_SUBSTR" '.[] | select(.name | contains($n)) | .pipeline_id' \
      | head -1)
  fi
fi

if [[ -n "$PIPELINE_ID" ]]; then
  # Stop the pipeline only if there's a RUNNING update.
  RUNNING=$(databricks pipelines list-updates "$PIPELINE_ID" --profile "$DATABRICKS_PROFILE" -o json 2>/dev/null \
    | jq -r '.updates[]? | select(.state == "RUNNING" or .state == "INITIALIZING" or .state == "RESETTING") | .update_id' \
    | head -1)
  if [[ -n "$RUNNING" ]]; then
    log "[Phase 1] Stopping pipeline $PIPELINE_ID (update $RUNNING)..."
    if databricks pipelines stop "$PIPELINE_ID" --profile "$DATABRICKS_PROFILE" >/dev/null 2>&1; then
      ok "[Phase 1] Pipeline stopped"
    else
      warn "[Phase 1] Stop pipeline" "CLI reported error — continuing"
    fi
  else
    skip "[Phase 1] Stop pipeline" "no running update"
  fi
else
  skip "[Phase 1] Pipeline lookup" "no pipeline *${PIPELINE_NAME_SUBSTR}* deployed"
fi

# Drop the Unity Catalog schema (CASCADE equivalent via `schemas delete`).
log "[Phase 1] Dropping schema $SCHEMA_FQN..."
DELETE_OUT=$(databricks schemas delete "$SCHEMA_FQN" --profile "$DATABRICKS_PROFILE" 2>&1)
DELETE_RC=$?
if [[ $DELETE_RC -eq 0 ]]; then
  ok "[Phase 1] Schema $SCHEMA_FQN dropped"
elif echo "$DELETE_OUT" | grep -qiE "does not exist|not found|NOT_FOUND"; then
  skip "[Phase 1] Schema $SCHEMA_FQN" "already absent"
else
  fail_phase "Phase 1 (schema delete)" "$DELETE_OUT"
fi

# ─── Phase 2 — Jira teardown ───────────────────────────────────────────────
log "[Phase 2] Fetching $JIRA_PROJECT Jira issues..."

SEARCH_URL="$JIRA_BASE/rest/api/3/search/jql"
SEARCH_JQL="project=$JIRA_PROJECT"
SEARCH_RESP=$(curl -sf -G "$SEARCH_URL" \
  --data-urlencode "jql=$SEARCH_JQL" \
  --data-urlencode "fields=key" \
  --data-urlencode "maxResults=100" \
  "${JIRA_AUTH[@]}" 2>/dev/null) || SEARCH_RESP=""

if [[ -z "$SEARCH_RESP" ]]; then
  # Could be empty project (old Jira responded 404) or real auth issue.
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -G "$SEARCH_URL" \
    --data-urlencode "jql=$SEARCH_JQL" --data-urlencode "maxResults=1" \
    "${JIRA_AUTH[@]}")
  if [[ "$HTTP_CODE" == "404" || "$HTTP_CODE" == "400" ]]; then
    skip "[Phase 2] Jira search" "project $JIRA_PROJECT not found (fresh state)"
    KEYS=""
  elif [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    fail_phase "Phase 2 (Jira search)" "HTTP $HTTP_CODE — check JIRA_EMAIL / JIRA_API_TOKEN and DLTDEMO project role"
    KEYS=""
  else
    fail_phase "Phase 2 (Jira search)" "HTTP $HTTP_CODE from $SEARCH_URL"
    KEYS=""
  fi
else
  KEYS=$(echo "$SEARCH_RESP" | jq -r '.issues[]?.key // empty')
fi

if [[ -n "$KEYS" ]]; then
  COUNT=$(echo "$KEYS" | wc -l | tr -d ' ')
  log "[Phase 2] Found $COUNT issue(s) — deleting..."
  for KEY in $KEYS; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
      "$JIRA_BASE/rest/api/3/issue/$KEY" "${JIRA_AUTH[@]}")
    case "$STATUS" in
      204|200)
        ok "[Phase 2] Deleted $KEY"
        ;;
      404)
        skip "[Phase 2] $KEY" "already deleted"
        ;;
      403)
        err "[Phase 2] $KEY" "HTTP 403 — Jira admin permissions required to delete issues; check DLTDEMO project role for $JIRA_EMAIL"
        EXIT_CODE=1
        FAILED_PHASE="${FAILED_PHASE:+$FAILED_PHASE, }Phase 2 (403 on $KEY)"
        exit 1
        ;;
      *)
        fail_phase "Phase 2 (delete $KEY)" "HTTP $STATUS"
        ;;
    esac
  done
elif [[ $EXIT_CODE -eq 0 ]]; then
  skip "[Phase 2] Jira delete" "no issues to remove"
fi

# Re-seed unless the search phase already failed.
if [[ $EXIT_CODE -eq 0 ]]; then
  log "[Phase 2] Re-seeding Jira project via seed-jira.sh..."
  SEED="$SCRIPT_DIR/seed-jira.sh"
  if [[ ! -f "$SEED" ]]; then
    fail_phase "Phase 2 (re-seed)" "scripts/seed-jira.sh not found (ticket 002 prerequisite)"
  else
    if bash "$SEED" >/dev/null 2>&1; then
      ok "[Phase 2] Jira re-seeded"
    else
      # Re-run with visible output so the operator sees the failure detail.
      err "[Phase 2] seed-jira.sh failed — re-running with output for diagnostics:"
      bash "$SEED" || true
      fail_phase "Phase 2 (re-seed)" "seed-jira.sh exited non-zero"
    fi
  fi
fi

# ─── Phase 3 — TDD teardown ────────────────────────────────────────────────
log "[Phase 3] Wiping .tdd/backlog and .tdd/completed..."

shopt -s nullglob
backlog_files=(.tdd/backlog/*.md)
completed_files=(.tdd/completed/*.md)
shopt -u nullglob
TOTAL=$(( ${#backlog_files[@]} + ${#completed_files[@]} ))
if [[ $TOTAL -gt 0 ]]; then
  [[ ${#backlog_files[@]}   -gt 0 ]] && rm -f "${backlog_files[@]}"
  [[ ${#completed_files[@]} -gt 0 ]] && rm -f "${completed_files[@]}"
  ok "[Phase 3] Removed $TOTAL ticket file(s)"
else
  skip "[Phase 3] Ticket wipe" "no ticket files present"
fi

log "[Phase 3] Resetting registry.json..."
# Schema pinned to version 3 — coupled to the TDD engine in use. Update in
# tandem if the engine upgrades.
cat > .tdd/registry.json <<EOF
{"version":3,"next_number":1,"tickets":{},"metrics":{"total_completed":0},"worktrees":{"main":{"path":"$REPO_ROOT","branch":"HEAD","tickets":{}}}}
EOF

# Sanity: jq can parse it + preserved dirs still exist.
if ! jq -e '.version == 3 and .next_number == 1' .tdd/registry.json >/dev/null; then
  fail_phase "Phase 3 (registry)" "registry.json failed post-write validation"
elif [[ ! -d .tdd/prds ]]; then
  fail_phase "Phase 3 (preservation)" ".tdd/prds/ missing after reset"
else
  ok "[Phase 3] registry.json reset (version 3, next_number 1)"
fi

exit $EXIT_CODE
