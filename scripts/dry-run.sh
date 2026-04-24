#!/usr/bin/env bash
# scripts/dry-run.sh — End-to-end dry-run with M1/M2/M3 measurement
#
# Executes 5 consecutive full demo cycles, capturing wall-clock timings per phase.
# Validates M1 (reset < 120s), M2 (e2e < 1500s), M3 (0 flakes).
# Produces artifacts/dry-run-<timestamp>/metrics.json and docs/dry-run-report.md.
#
# Usage: bash scripts/dry-run.sh [--auto] [--cycles N] [--hard-mode-cycle N] [-h|--help]
#
#   --auto            Skip confirmation prompts (use with caution)
#   --cycles N        Run N cycles instead of default 5
#   --hard-mode-cycle N  Which cycle uses --hard-mode (default: 3)
#   -h, --help        Show this help message
#
# Requires: bash 4+, curl, jq, databricks CLI
# Env vars: JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN

set -uo pipefail

# ─── Script-root resolution ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ─── Defaults ──────────────────────────────────────────────────────────────
AUTO_MODE=0
TOTAL_CYCLES=5
HARD_MODE_CYCLE=3
DATABRICKS_PROFILE="julien-compass"
SCHEMA_FQN="sandbox.dltdemo"

# ─── Argument parsing ──────────────────────────────────────────────────────
show_help() {
  cat <<'EOF'
Usage: dry-run.sh [OPTIONS]

End-to-end dry-run with M1/M2/M3 measurement and flake detection.

Options:
  --auto                Skip confirmation prompts
  --cycles N            Number of cycles to run (default: 5)
  --hard-mode-cycle N   Which cycle uses --hard-mode seed (default: 3)
  -h, --help            Show this help message

Required environment variables:
  JIRA_DOMAIN       Atlassian domain
  JIRA_EMAIL        Jira account email
  JIRA_API_TOKEN    API token

Output:
  artifacts/dry-run-<timestamp>/metrics.json   Machine-readable metrics
  artifacts/dry-run-<timestamp>/cycle-*.json   Per-cycle incremental data
  docs/dry-run-report.md                       Human-readable report
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto)            AUTO_MODE=1; shift ;;
    --cycles)          TOTAL_CYCLES="$2"; shift 2 ;;
    --hard-mode-cycle) HARD_MODE_CYCLE="$2"; shift 2 ;;
    -h|--help)         show_help; exit 0 ;;
    *)
      printf "Unknown flag: %s\nRun with --help for usage.\n" "$1" >&2
      exit 2
      ;;
  esac
done

# ─── Colors (TTY-aware) ────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  RED=$'\033[0;31m'
  BLUE=$'\033[0;34m'
  DIM=$'\033[2m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  GREEN="" YELLOW="" RED="" BLUE="" DIM="" BOLD="" RESET=""
fi

log()   { printf "${DIM}[%s]${RESET} %s\n" "$(date '+%H:%M:%S')" "$*"; }
ok()    { printf "${DIM}[%s]${RESET} %s ${GREEN}✓${RESET}\n" "$(date '+%H:%M:%S')" "$*"; }
warn()  { printf "${DIM}[%s]${RESET} %s ${YELLOW}⚠${RESET} %s\n" "$(date '+%H:%M:%S')" "$1" "${2:-}" >&2; }
err()   { printf "${DIM}[%s]${RESET} %s ${RED}✗${RESET} %s\n" "$(date '+%H:%M:%S')" "$1" "${2:-}" >&2; }
info()  { printf "${BLUE}▸${RESET} %s\n" "$*"; }
phase() { printf "\n${BOLD}%s${RESET}\n" "$*"; }

# ─── Setup ─────────────────────────────────────────────────────────────────
TS=$(date -u +%Y%m%dT%H%M%SZ)
ARTIFACTS_DIR="$REPO_ROOT/artifacts/dry-run-$TS"
mkdir -p "$ARTIFACTS_DIR"

METRICS_FILE="$ARTIFACTS_DIR/metrics.json"
DRY_RUN_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log "Artifacts directory: $ARTIFACTS_DIR"

# ─── Metrics structure ─────────────────────────────────────────────────────
init_metrics() {
  cat > "$METRICS_FILE" <<EOF
{
  "dry_run_date": "$DRY_RUN_DATE",
  "workspace": "julien-compass",
  "catalog": "sandbox",
  "schema": "dltdemo",
  "total_cycles": $TOTAL_CYCLES,
  "hard_mode_cycle": $HARD_MODE_CYCLE,
  "cycles": [],
  "summary": {},
  "m5": {},
  "fixes_applied": [],
  "follow_up_tickets": [],
  "notes": []
}
EOF
}

update_cycles() {
  local tmp="$(mktemp)"
  jq --argjson cycles "$1" '.cycles = $cycles' "$METRICS_FILE" > "$tmp" && mv "$tmp" "$METRICS_FILE"
}

update_summary() {
  local tmp="$(mktemp)"
  jq --argjson summary "$1" '.summary = $summary' "$METRICS_FILE" > "$tmp" && mv "$tmp" "$METRICS_FILE"
}

update_m5() {
  local tmp="$(mktemp)"
  jq --argjson m5 "$1" '.m5 = $m5' "$METRICS_FILE" > "$tmp" && mv "$tmp" "$METRICS_FILE"
}

add_note() {
  local note="$1"
  local tmp="$(mktemp)"
  jq --arg note "$note" '.notes += [$note]' "$METRICS_FILE" > "$tmp" && mv "$tmp" "$METRICS_FILE"
}

add_fix() {
  local fix="$1"
  local tmp="$(mktemp)"
  jq --arg fix "$fix" '.fixes_applied += [$fix]' "$METRICS_FILE" > "$tmp" && mv "$tmp" "$METRICS_FILE"
}

add_follow_up() {
  local ticket="$1"
  local tmp="$(mktemp)"
  jq --arg ticket "$ticket" '.follow_up_tickets += [$ticket]' "$METRICS_FILE" > "$tmp" && mv "$tmp" "$METRICS_FILE"
}

# ─── Timing helpers ────────────────────────────────────────────────────────
start_timer() {
  TIMER_START=$(date +%s)
}

elapsed_seconds() {
  local now=$(date +%s)
  echo $((now - TIMER_START))
}

# ─── Verification helpers ──────────────────────────────────────────────────
verify_tables() {
  local cycle="$1"
  local tables=("bronze_customers" "bronze_orders" "silver_customer_summary")
  local all_found=1

  log "[Cycle $cycle] Verifying Unity Catalog tables..."
  for table in "${tables[@]}"; do
    local full_name="$SCHEMA_FQN.$table"
    if databricks tables get "$full_name" --profile "$DATABRICKS_PROFILE" >/dev/null 2>&1; then
      ok "[Cycle $cycle] Table $full_name exists"
    else
      err "[Cycle $cycle] Table $full_name NOT FOUND"
      all_found=0
    fi
  done

  return $((1 - all_found))
}

# ─── Prompt helpers ────────────────────────────────────────────────────────
wait_for_user() {
  local prompt="$1"
  if [[ $AUTO_MODE -eq 1 ]]; then
    log "AUTO MODE: $prompt"
    return 0
  fi
  printf "\n${YELLOW}%s${RESET}\n" "$prompt"
  read -rp "Press Enter when ready to continue..."
}

# ─── Prerequisites ─────────────────────────────────────────────────────────
phase "=== Dry-Run Prerequisites ==="

missing=()
for v in JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN; do
  [[ -z "${!v:-}" ]] && missing+=("$v")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  err "Missing required env vars: ${missing[*]}"
  exit 1
fi

for cmd in jq curl databricks; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "Missing required command: $cmd"
    exit 1
  fi
done

if ! databricks current-user me --profile "$DATABRICKS_PROFILE" -o json >/dev/null 2>&1; then
  err "Databricks profile '$DATABRICKS_PROFILE' not authenticated"
  exit 1
fi

init_metrics
ok "Prerequisites OK"

# ─── M5 Validation (once, before cycles) ───────────────────────────────────
phase "=== M5 Validation: jira-to-tdd against real project ==="

info "M5 requires a real non-demo Compass Jira project."
info "The project must: (a) exist, (b) have issues, (c) be safe to run against."

if [[ $AUTO_MODE -eq 1 ]]; then
  warn "M5" "AUTO MODE — skipping M5 (requires manual project selection). Run manually later."
  update_m5 '{"project_key": "SKIPPED", "issues_fetched": 0, "tickets_created": 0, "outcome": "skipped", "notes": "Skipped in auto mode — requires manual project selection"}'
else
  read -rp "Enter a real Jira project key for M5 validation (or 'skip' to skip): " M5_PROJECT
  if [[ "$M5_PROJECT" == "skip" || -z "$M5_PROJECT" ]]; then
    warn "M5" "Skipped by user"
    update_m5 '{"project_key": "SKIPPED", "issues_fetched": 0, "tickets_created": 0, "outcome": "skipped", "notes": "Skipped by user"}'
  else
    log "Running M5 validation against project: $M5_PROJECT"

    M5_SCRATCH="/tmp/m5-scratch-$$"
    mkdir -p "$M5_SCRATCH/.tdd"/{backlog,completed}
    echo '{"version":3,"next_number":1,"tickets":{},"metrics":{"total_completed":0}}' > "$M5_SCRATCH/.tdd/registry.json"

    # Note: We can't actually run /jira-to-tdd from bash — it's a Claude skill.
    # We document that the user should run it manually.
    warn "M5" "Cannot run /jira-to-tdd from bash script — this is a Claude skill."
    info "To complete M5 manually:"
    info "  cd $M5_SCRATCH"
    info "  /jira-to-tdd $M5_PROJECT"
    info "  Then check: ls $M5_SCRATCH/.tdd/backlog/"

    update_m5 "{\"project_key\": \"$M5_PROJECT\", \"issues_fetched\": 0, \"tickets_created\": 0, \"outcome\": \"manual_required\", \"notes\": \"User must run /jira-to-tdd $M5_PROJECT in $M5_SCRATCH\"}"

    wait_for_user "Run /jira-to-tdd $M5_PROJECT in a Claude session, then return here."
  fi
fi

# ─── Main cycle loop ───────────────────────────────────────────────────────
phase "=== Dry-Run Cycles ==="

info "Running $TOTAL_CYCLES cycles. Hard-mode on cycle $HARD_MODE_CYCLE."
info "Each cycle: health-check → reset → seed → demo → verify tables"

CYCLES_JSON="[]"
FLAKES=0

for ((CYCLE=1; CYCLE<=TOTAL_CYCLES; CYCLE++)); do
  phase "=== Cycle $CYCLE / $TOTAL_CYCLES ==="

  CYCLE_FILE="$ARTIFACTS_DIR/cycle-$CYCLE.json"
  CYCLE_START=$(date +%s)

  # Determine if this is hard-mode
  IS_HARD_MODE=0
  SEED_ARGS=""
  if [[ "$CYCLE" -eq "$HARD_MODE_CYCLE" ]]; then
    IS_HARD_MODE=1
    SEED_ARGS="--hard-mode"
    info "Cycle $CYCLE: HARD MODE — broken acceptance criteria for DLTDEMO-3"
  fi

  # ─── Step 1: Health-check ────────────────────────────────────────────────
  log "[Cycle $CYCLE] Running health-check..."
  start_timer
  if ! bash "$SCRIPT_DIR/health-check.sh"; then
    err "[Cycle $CYCLE] Health-check FAILED"
    warn "A failed health-check does NOT count as a flake — it prevents a doomed run."
    warn "Fix the health-check failures, then re-run dry-run.sh."
    exit 1
  fi
  HEALTH_CHECK_DURATION=$(elapsed_seconds)
  ok "[Cycle $CYCLE] Health-check passed (${HEALTH_CHECK_DURATION}s)"

  # ─── Step 2: Reset ───────────────────────────────────────────────────────
  log "[Cycle $CYCLE] Running reset-demo.sh..."
  start_timer
  if ! bash "$SCRIPT_DIR/reset-demo.sh"; then
    err "[Cycle $CYCLE] Reset FAILED"
    FLAKES=$((FLAKES + 1))
    add_note "Cycle $CYCLE: reset-demo.sh failed"

    CYCLE_END=$(date +%s)
    CYCLE_DURATION=$((CYCLE_END - CYCLE_START))

    CYCLE_OBJ=$(jq -n \
      --argjson cycle "$CYCLE" \
      --argjson hard_mode "$IS_HARD_MODE" \
      --argjson reset_duration "$(elapsed_seconds)" \
      --argjson health_check_duration "$HEALTH_CHECK_DURATION" \
      --argjson total_e2e_duration "$CYCLE_DURATION" \
      --arg outcome "fail" \
      --arg failure_phase "reset" \
      '{cycle: $cycle, hard_mode: $hard_mode, reset_duration: $reset_duration, health_check_duration: $health_check_duration, total_e2e_duration: $total_e2e_duration, outcome: $outcome, failure_phase: $failure_phase}')

    CYCLES_JSON=$(echo "$CYCLES_JSON" | jq --argjson obj "$CYCLE_OBJ" '. + [$obj]')
    update_cycles "$CYCLES_JSON"

    if [[ $AUTO_MODE -eq 0 ]]; then
      read -rp "Reset failed. Continue to next cycle? [y/N]: " CONTINUE
      [[ "$CONTINUE" =~ ^[Yy]$ ]] || break
    fi
    continue
  fi
  RESET_DURATION=$(elapsed_seconds)
  ok "[Cycle $CYCLE] Reset completed (${RESET_DURATION}s)"

  # ─── Step 3: Seed Jira ───────────────────────────────────────────────────
  log "[Cycle $CYCLE] Seeding Jira..."
  start_timer
  if ! bash "$SCRIPT_DIR/seed-jira.sh" $SEED_ARGS; then
    err "[Cycle $CYCLE] Jira seed FAILED"
    FLAKES=$((FLAKES + 1))
    add_note "Cycle $CYCLE: seed-jira.sh failed"

    CYCLE_END=$(date +%s)
    CYCLE_DURATION=$((CYCLE_END - CYCLE_START))

    CYCLE_OBJ=$(jq -n \
      --argjson cycle "$CYCLE" \
      --argjson hard_mode "$IS_HARD_MODE" \
      --argjson reset_duration "$RESET_DURATION" \
      --argjson health_check_duration "$HEALTH_CHECK_DURATION" \
      --argjson total_e2e_duration "$CYCLE_DURATION" \
      --arg outcome "fail" \
      --arg failure_phase "seed" \
      '{cycle: $cycle, hard_mode: $hard_mode, reset_duration: $reset_duration, health_check_duration: $health_check_duration, total_e2e_duration: $total_e2e_duration, outcome: $outcome, failure_phase: $failure_phase}')

    CYCLES_JSON=$(echo "$CYCLES_JSON" | jq --argjson obj "$CYCLE_OBJ" '. + [$obj]')
    update_cycles "$CYCLES_JSON"

    if [[ $AUTO_MODE -eq 0 ]]; then
      read -rp "Seed failed. Continue to next cycle? [y/N]: " CONTINUE
      [[ "$CONTINUE" =~ ^[Yy]$ ]] || break
    fi
    continue
  fi
  SEED_DURATION=$(elapsed_seconds)
  ok "[Cycle $CYCLE] Jira seeded (${SEED_DURATION}s)"

  # ─── Step 4: Interactive Demo ────────────────────────────────────────────
  info ""
  info "────────────────────────────────────────────────────────────"
  info "  INTERACTIVE DEMO PHASE — Cycle $CYCLE"
  info "────────────────────────────────────────────────────────────"
  info ""
  info "  Run these commands in a Claude Code session:"
  info ""
  info "  1. Import Jira tickets into TDD:"
  info "       /jira-to-tdd DLTDEMO"
  info ""
  info "  2. Tackle tickets (parallel where possible):"
  info "       /ralph-tackle"
  info "     Or individually:"
  info "       /tackle 001"
  info "       /tackle 002"
  info "       /tackle 003"
  info ""
  info "  3. After all tickets complete, verify tables:"
  info "       databricks tables list sandbox.dltdemo --profile julien-compass"
  info ""
  if [[ "$IS_HARD_MODE" -eq 1 ]]; then
    info "  HARD MODE: DLTDEMO-3 has broken acceptance criteria."
    info "  The tackle session should detect the schema mismatch and fix it."
    info ""
  fi
  info "────────────────────────────────────────────────────────────"
  info ""

  DEMO_START=$(date +%s)
  wait_for_user "Complete the demo steps above, then press Enter."
  DEMO_END=$(date +%s)
  DEMO_DURATION=$((DEMO_END - DEMO_START))
  ok "[Cycle $CYCLE] Demo phase completed (${DEMO_DURATION}s)"

  # ─── Step 5: Verify tables ───────────────────────────────────────────────
  log "[Cycle $CYCLE] Verifying tables..."
  start_timer
  if verify_tables "$CYCLE"; then
    VERIFY_DURATION=$(elapsed_seconds)
    ok "[Cycle $CYCLE] All tables verified (${VERIFY_DURATION}s)"
  else
    err "[Cycle $CYCLE] Table verification FAILED"
    FLAKES=$((FLAKES + 1))
    add_note "Cycle $CYCLE: Table verification failed"

    CYCLE_END=$(date +%s)
    CYCLE_DURATION=$((CYCLE_END - CYCLE_START))

    CYCLE_OBJ=$(jq -n \
      --argjson cycle "$CYCLE" \
      --argjson hard_mode "$IS_HARD_MODE" \
      --argjson reset_duration "$RESET_DURATION" \
      --argjson health_check_duration "$HEALTH_CHECK_DURATION" \
      --argjson seed_duration "$SEED_DURATION" \
      --argjson demo_duration "$DEMO_DURATION" \
      --argjson total_e2e_duration "$CYCLE_DURATION" \
      --arg outcome "fail" \
      --arg failure_phase "verify" \
      '{cycle: $cycle, hard_mode: $hard_mode, reset_duration: $reset_duration, health_check_duration: $health_check_duration, seed_duration: $seed_duration, demo_duration: $demo_duration, total_e2e_duration: $total_e2e_duration, outcome: $outcome, failure_phase: $failure_phase}')

    CYCLES_JSON=$(echo "$CYCLES_JSON" | jq --argjson obj "$CYCLE_OBJ" '. + [$obj]')
    update_cycles "$CYCLES_JSON"

    if [[ $AUTO_MODE -eq 0 ]]; then
      read -rp "Verification failed. Continue to next cycle? [y/N]: " CONTINUE
      [[ "$CONTINUE" =~ ^[Yy]$ ]] || break
    fi
    continue
  fi

  # ─── Cycle success ───────────────────────────────────────────────────────
  CYCLE_END=$(date +%s)
  CYCLE_DURATION=$((CYCLE_END - CYCLE_START))

  CYCLE_OBJ=$(jq -n \
    --argjson cycle "$CYCLE" \
    --argjson hard_mode "$IS_HARD_MODE" \
    --argjson reset_duration "$RESET_DURATION" \
    --argjson health_check_duration "$HEALTH_CHECK_DURATION" \
    --argjson seed_duration "$SEED_DURATION" \
    --argjson demo_duration "$DEMO_DURATION" \
    --argjson verify_duration "$VERIFY_DURATION" \
    --argjson total_e2e_duration "$CYCLE_DURATION" \
    --arg outcome "pass" \
    '{cycle: $cycle, hard_mode: $hard_mode, reset_duration: $reset_duration, health_check_duration: $health_check_duration, seed_duration: $seed_duration, demo_duration: $demo_duration, verify_duration: $verify_duration, total_e2e_duration: $total_e2e_duration, outcome: $outcome}')

  CYCLES_JSON=$(echo "$CYCLES_JSON" | jq --argjson obj "$CYCLE_OBJ" '. + [$obj]')
  update_cycles "$CYCLES_JSON"

  # Write incremental cycle file
  echo "$CYCLE_OBJ" > "$CYCLE_FILE"

  ok "[Cycle $CYCLE] COMPLETE — total: ${CYCLE_DURATION}s"

  # M1 check
  if [[ "$RESET_DURATION" -gt 120 ]]; then
    warn "[Cycle $CYCLE] M1 BREACH: reset took ${RESET_DURATION}s (target: <120s)"
    add_note "Cycle $CYCLE: M1 breach — reset ${RESET_DURATION}s > 120s"
  fi

  # M2 check
  if [[ "$CYCLE_DURATION" -gt 1500 ]]; then
    warn "[Cycle $CYCLE] M2 BREACH: e2e took ${CYCLE_DURATION}s (target: <1500s)"
    add_note "Cycle $CYCLE: M2 breach — e2e ${CYCLE_DURATION}s > 1500s"
  fi
done

# ─── Compute distributions ─────────────────────────────────────────────────
phase "=== Computing Metrics ==="

M1_MIN=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass") | .reset_duration] | min // 0')
M1_MAX=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass") | .reset_duration] | max // 0')
M1_P50=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass") | .reset_duration] | if length > 0 then sort | if length % 2 == 1 then .[(length-1)/2] else (.[length/2 - 1] + .[length/2]) / 2 end else 0 end')
M1_PASS=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass" and .reset_duration < 120)] | length')
M1_TOTAL=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass")] | length')

M2_MIN=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass") | .total_e2e_duration] | min // 0')
M2_MAX=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass") | .total_e2e_duration] | max // 0')
M2_P50=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass") | .total_e2e_duration] | if length > 0 then sort | if length % 2 == 1 then .[(length-1)/2] else (.[length/2 - 1] + .[length/2]) / 2 end else 0 end')
M2_PASS=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass" and .total_e2e_duration < 1500)] | length')
M2_TOTAL=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass")] | length')

CYCLES_PASSED=$(echo "$CYCLES_JSON" | jq '[.[] | select(.outcome == "pass")] | length')

SUMMARY=$(jq -n \
  --argjson m1_min "$M1_MIN" \
  --argjson m1_max "$M1_MAX" \
  --argjson m1_p50 "$M1_P50" \
  --argjson m1_all_pass "$([[ "$M1_PASS" -eq "$M1_TOTAL" && "$M1_TOTAL" -gt 0 ]] && echo true || echo false)" \
  --argjson m2_min "$M2_MIN" \
  --argjson m2_max "$M2_MAX" \
  --argjson m2_p50 "$M2_P50" \
  --argjson m2_all_pass "$([[ "$M2_PASS" -eq "$M2_TOTAL" && "$M2_TOTAL" -gt 0 ]] && echo true || echo false)" \
  --argjson flakes "$FLAKES" \
  --argjson cycles_passed "$CYCLES_PASSED" \
  --argjson m3_pass "$([[ "$FLAKES" -eq 0 ]] && echo true || echo false)" \
  '{
    m1: {min: $m1_min, max: $m1_max, p50: $m1_p50, all_pass: $m1_all_pass},
    m2: {min: $m2_min, max: $m2_max, p50: $m2_p50, all_pass: $m2_all_pass},
    m3: {flakes: $flakes, cycles_passed: $cycles_passed, pass: $m3_pass}
  }')

update_summary "$SUMMARY"

ok "Metrics computed and saved to $METRICS_FILE"

# ─── Generate report ───────────────────────────────────────────────────────
phase "=== Generating Report ==="

REPORT_FILE="$REPO_ROOT/docs/dry-run-report.md"

DEMO_READY="NOT READY"
BLOCKERS=""
if [[ "$FLAKES" -gt 0 ]]; then
  BLOCKERS="${BLOCKERS}- $FLAKES flake(s) detected\n"
fi
if [[ "$M1_PASS" -ne "$M1_TOTAL" || "$M1_TOTAL" -eq 0 ]]; then
  BLOCKERS="${BLOCKERS}- M1 gate failed (reset > 120s in some cycles)\n"
fi
if [[ "$M2_PASS" -ne "$M2_TOTAL" || "$M2_TOTAL" -eq 0 ]]; then
  BLOCKERS="${BLOCKERS}- M2 gate failed (e2e > 1500s in some cycles)\n"
fi

if [[ -z "$BLOCKERS" && "$CYCLES_PASSED" -eq "$TOTAL_CYCLES" ]]; then
  DEMO_READY="READY"
fi

cat > "$REPORT_FILE" <<EOF
# Dry-Run Report

**Date:** $DRY_RUN_DATE  
**Workspace:** julien-compass  
**Catalog:** sandbox  
**Schema:** dltdemo  
**Cycles:** $TOTAL_CYCLES  
**Hard-mode cycle:** $HARD_MODE_CYCLE

---

## Demo Readiness Verdict

**$DEMO_READY**

EOF

if [[ -n "$BLOCKERS" ]]; then
  cat >> "$REPORT_FILE" <<EOF
**Blockers:**

$(echo -e "$BLOCKERS")
EOF
else
  cat >> "$REPORT_FILE" <<EOF
No blockers. All gates passed.
EOF
fi

cat >> "$REPORT_FILE" <<EOF

---

## Metrics Summary

### M1 — Reset Duration (target: < 120s)

| Metric | Value |
|--------|-------|
| Min    | ${M1_MIN}s |
| Max    | ${M1_MAX}s |
| P50    | ${M1_P50}s |
| Pass   | $M1_PASS / $M1_TOTAL cycles |

### M2 — End-to-End Duration (target: < 1500s)

| Metric | Value |
|--------|-------|
| Min    | ${M2_MIN}s |
| Max    | ${M2_MAX}s |
| P50    | ${M2_P50}s |
| Pass   | $M2_PASS / $M2_TOTAL cycles |

### M3 — Flakes (target: 0)

| Metric | Value |
|--------|-------|
| Flakes | $FLAKES |
| Cycles Passed | $CYCLES_PASSED / $TOTAL_CYCLES |

---

## Per-Cycle Breakdown

EOF

# Add per-cycle table
{
  echo "| Cycle | Hard Mode | Reset | Seed | Demo | Verify | Total | Outcome |"
  echo "|-------|-----------|-------|------|------|--------|-------|---------|"
  echo "$CYCLES_JSON" | jq -r '.[] | "| \(.cycle) | \(.hard_mode) | \(.reset_duration // "—") | \(.seed_duration // "—") | \(.demo_duration // "—") | \(.verify_duration // "—") | \(.total_e2e_duration) | \(.outcome)\(.failure_phase // "" | if . != "" then " (" + . + ")" else "" end) |"'
} >> "$REPORT_FILE"

cat >> "$REPORT_FILE" <<EOF

---

## M5 Validation

EOF

M5_PROJECT_KEY=$(jq -r '.m5.project_key // "N/A"' "$METRICS_FILE")
M5_OUTCOME=$(jq -r '.m5.outcome // "N/A"' "$METRICS_FILE")
M5_NOTES=$(jq -r '.m5.notes // ""' "$METRICS_FILE")

cat >> "$REPORT_FILE" <<EOF
- **Project Key:** $M5_PROJECT_KEY
- **Outcome:** $M5_OUTCOME
- **Notes:** $M5_NOTES

---

## Fixes Applied

EOF

FIXES_COUNT=$(jq '.fixes_applied | length' "$METRICS_FILE")
if [[ "$FIXES_COUNT" -gt 0 ]]; then
  jq -r '.fixes_applied[] | "- " + .' "$METRICS_FILE" >> "$REPORT_FILE"
else
  echo "No inline fixes applied." >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<EOF

---

## Follow-Up Tickets

EOF

FOLLOWUPS_COUNT=$(jq '.follow_up_tickets | length' "$METRICS_FILE")
if [[ "$FOLLOWUPS_COUNT" -gt 0 ]]; then
  jq -r '.follow_up_tickets[] | "- " + .' "$METRICS_FILE" >> "$REPORT_FILE"
else
  echo "No follow-up tickets filed." >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<EOF

---

## Notes

EOF

NOTES_COUNT=$(jq '.notes | length' "$METRICS_FILE")
if [[ "$NOTES_COUNT" -gt 0 ]]; then
  jq -r '.notes[] | "- " + .' "$METRICS_FILE" >> "$REPORT_FILE"
else
  echo "No additional notes." >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<EOF

---

## Artifacts

- Machine-readable metrics: \`$METRICS_FILE\`
- Per-cycle data: \`$ARTIFACTS_DIR/cycle-*.json\`
EOF

ok "Report generated: $REPORT_FILE"

# ─── Final summary ─────────────────────────────────────────────────────────
phase "=== Dry-Run Complete ==="

echo ""
echo "${BOLD}Results:${RESET}"
echo "  M1 (reset < 120s):     $M1_PASS / $M1_TOTAL passed"
echo "  M2 (e2e < 1500s):      $M2_PASS / $M2_TOTAL passed"
echo "  M3 (flakes):           $FLAKES"
echo "  Cycles passed:         $CYCLES_PASSED / $TOTAL_CYCLES"
echo "  Demo readiness:        $DEMO_READY"
echo ""
echo "${BOLD}Artifacts:${RESET}"
echo "  Metrics:  $METRICS_FILE"
echo "  Report:   $REPORT_FILE"
echo ""

if [[ "$DEMO_READY" == "READY" ]]; then
  echo "${GREEN}All gates passed. Demo is ready.${RESET}"
  exit 0
else
  echo "${YELLOW}Demo is NOT ready. See report for blockers.${RESET}"
  exit 1
fi
