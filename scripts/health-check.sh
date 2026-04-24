#!/usr/bin/env bash
set -uo pipefail

PASS=0
FAIL=0
CHECKS_TOTAL=6
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

run_with_timeout() {
  local secs="$1"
  shift
  ( "$@" ) &
  local pid=$!
  ( sleep "$secs" && kill $pid 2>/dev/null ) &
  local killer=$!
  wait $pid 2>/dev/null
  local status=$?
  kill $killer 2>/dev/null
  return $status
}

check_pass() {
  echo "[PASS] $1"
  PASS=$((PASS + 1))
}

check_fail() {
  echo "[FAIL] $1 — $2"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
# Check 1: Databricks Auth
# ---------------------------------------------------------------------------
output=$(run_with_timeout 5 databricks current-user me --profile julien-compass -o json 2>/dev/null) || true
if [ -n "$output" ] && echo "$output" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  check_pass "Databricks Auth"
else
  check_fail "Databricks Auth" "run: databricks auth login --profile julien-compass"
fi

# ---------------------------------------------------------------------------
# Check 2: Jira Reachability
# ---------------------------------------------------------------------------
if [ -z "${JIRA_DOMAIN:-}" ] || [ -z "${JIRA_EMAIL:-}" ] || [ -z "${JIRA_API_TOKEN:-}" ]; then
  check_fail "Jira Reachability" "Set JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN env vars"
else
  DOMAIN="${JIRA_DOMAIN#https://}"
  DOMAIN="${DOMAIN#http://}"
  http_code=$(run_with_timeout 5 curl -sS -o /dev/null -w "%{http_code}" -G "https://$DOMAIN/rest/api/3/search/jql" \
    --data-urlencode "jql=project=DLTDEMO ORDER BY created ASC" \
    --data-urlencode "maxResults=1" \
    -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
    -H "Accept: application/json" 2>/dev/null) || true

  if [ "${http_code:-}" = "200" ]; then
    check_pass "Jira Reachability"
  else
    check_fail "Jira Reachability" "Verify env vars and JIRA_DOMAIN connectivity"
  fi
fi

# ---------------------------------------------------------------------------
# Check 3: Unity Catalog Sandbox
# ---------------------------------------------------------------------------
output=$(run_with_timeout 5 databricks schemas list sandbox --profile julien-compass 2>/dev/null) || true
if [ -n "${output:-}" ]; then
  check_pass "Unity Catalog Sandbox"
else
  check_fail "Unity Catalog Sandbox" "Check UC permissions for the julien-compass principal"
fi

# ---------------------------------------------------------------------------
# Check 4: TDD Registry Clean Baseline
# ---------------------------------------------------------------------------
count=$(find "$REPO_ROOT/.tdd/backlog" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "${count:-0}" -eq 0 ]; then
  check_pass "TDD Registry Clean Baseline"
else
  check_fail "TDD Registry Clean Baseline" "Run ./scripts/reset-demo.sh to clear the backlog"
fi

# ---------------------------------------------------------------------------
# Check 5: Seed CSVs Committed
# ---------------------------------------------------------------------------
if [ -f "$REPO_ROOT/databricks/src/seed_data/customers.csv" ] && [ -s "$REPO_ROOT/databricks/src/seed_data/customers.csv" ] && \
   [ -f "$REPO_ROOT/databricks/src/seed_data/orders.csv" ] && [ -s "$REPO_ROOT/databricks/src/seed_data/orders.csv" ]; then
  check_pass "Seed CSVs Committed"
else
  check_fail "Seed CSVs Committed" "Commit seed CSVs or run ticket #5 first"
fi

# ---------------------------------------------------------------------------
# Check 6: DAB Bundle Valid
# ---------------------------------------------------------------------------
if (cd "$REPO_ROOT/databricks" && run_with_timeout 5 databricks bundle validate --profile julien-compass >/dev/null 2>&1); then
  check_pass "DAB Bundle Valid"
else
  check_fail "DAB Bundle Valid" "Check databricks/databricks.yml syntax — run: databricks bundle validate"
fi

# ---------------------------------------------------------------------------
# Summary footer
# ---------------------------------------------------------------------------
echo ""
echo "$PASS/$CHECKS_TOTAL checks passed."

if [ "$PASS" -eq "$CHECKS_TOTAL" ]; then
  echo "All checks passed. Demo ready."
  exit 0
else
  echo "Demo NOT ready — fix failures above before presenting."
  exit 1
fi
