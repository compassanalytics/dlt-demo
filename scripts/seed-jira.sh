#!/usr/bin/env bash
# scripts/seed-jira.sh — provision DLTDEMO Jira project + 3 linked issues
#
# Creates a DLTDEMO project containing three issues in a diamond dependency
# graph: DLTDEMO-3 (silver table C) is blocked by DLTDEMO-1 and DLTDEMO-2
# (bronze tables A and B).
#
# Idempotent: safe to re-run. Existing project, issues, and links are reused.
# Extra issues beyond the 3 canonical ones are silently ignored.
#
# Usage: bash scripts/seed-jira.sh [--hard-mode] [-h|--help]
#
# Requires: curl, jq
# Env vars: JIRA_DOMAIN, JIRA_EMAIL, JIRA_API_TOKEN
set -euo pipefail

# ─── Argument parsing ──────────────────────────────────────────────────────
HARD_MODE=0

show_help() {
  cat <<'EOF'
Usage: seed-jira.sh [OPTIONS]

Provision the DLTDEMO Jira project with 3 linked issues (diamond dependency graph).
Safe to re-run — existing project, issues, and links are reused.

Options:
  --hard-mode   Seed DLTDEMO-3 with intentionally broken acceptance criteria
                (customerid typo) to trigger the fix-and-retry demo scenario.
  -h, --help    Show this help message.

Required environment variables:
  JIRA_DOMAIN       Atlassian domain, e.g. yourcompany.atlassian.net
  JIRA_EMAIL        Your Jira account email
  JIRA_API_TOKEN    API token from https://id.atlassian.com/manage-profile/security/api-tokens
EOF
}

for arg in "$@"; do
  case "$arg" in
    --hard-mode) HARD_MODE=1 ;;
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
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  GREEN="" YELLOW="" RED="" BOLD="" RESET=""
fi

ok()   { printf "%s\n" "${GREEN}✓${RESET} $*"; }
skip() { printf "%s\n" "${YELLOW}→${RESET} $*"; }
err()  { printf "%s\n" "${RED}✗${RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# ─── Hard-mode banner ─────────────────────────────────────────────────────
if [[ "$HARD_MODE" -eq 1 ]]; then
  printf "\n%s\n" "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════════╗${RESET}"
  printf "%s\n"   "${BOLD}${YELLOW}║  [HARD MODE] Seeding broken acceptance criteria for          ║${RESET}"
  printf "%s\n"   "${BOLD}${YELLOW}║  DLTDEMO-3 — pipeline will need fix-and-retry.               ║${RESET}"
  printf "%s\n\n" "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════════╝${RESET}"
fi

# ─── Env var validation ────────────────────────────────────────────────────
missing=()
for v in JIRA_DOMAIN JIRA_EMAIL JIRA_API_TOKEN; do
  [[ -z "${!v:-}" ]] && missing+=("$v")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  err "Missing required environment variables: ${missing[*]}"
  printf "  Set them in your shell profile or export before running:\n" >&2
  for v in "${missing[@]}"; do
    printf "    export %s=\"...\"\n" "$v" >&2
  done
  exit 1
fi

DOMAIN="${JIRA_DOMAIN#https://}"
DOMAIN="${DOMAIN#http://}"
AUTH=(-u "$JIRA_EMAIL:$JIRA_API_TOKEN")
API="https://$DOMAIN/rest/api/3"

# ─── curl wrapper ──────────────────────────────────────────────────────────
# jira_req <METHOD> <path> <body_or_empty> <outfile>
# Writes response body to outfile; echoes HTTP status code to stdout.
# curl exit code is propagated — non-zero means network/TLS failure.
jira_req() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local outfile="$4"
  local curl_args=(-sS -w '%{http_code}' -o "$outfile"
    "${AUTH[@]}"
    -H 'Accept: application/json'
    -X "$method"
    "$API$path")
  if [[ -n "$body" ]]; then
    curl_args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  curl "${curl_args[@]}"
}

# jira_search <jql> <fields> <outfile>
# Uses curl's --data-urlencode for safe JQL encoding.
jira_search() {
  local jql="$1"
  local fields="${2:-summary,key}"
  local outfile="$3"
  curl -sS -w '%{http_code}' -o "$outfile" \
    "${AUTH[@]}" \
    -H 'Accept: application/json' \
    --get \
    --data-urlencode "jql=${jql}" \
    --data-urlencode "maxResults=10" \
    --data-urlencode "fields=${fields}" \
    "$API/search"
}

# ─── Auth check ───────────────────────────────────────────────────────────
printf "Validating credentials against %s... " "$DOMAIN"
_auth_tmp=$(mktemp)
_auth_code=$(jira_req GET /myself "" "$_auth_tmp")
if [[ "$_auth_code" != "200" ]]; then
  printf "\n" >&2
  case "$_auth_code" in
    401) err "Authentication failed (HTTP 401). Verify JIRA_EMAIL and JIRA_API_TOKEN."
         printf "  Generate an API token at: https://id.atlassian.com/manage-profile/security/api-tokens\n" >&2 ;;
    403) err "Access forbidden (HTTP 403). Your account may lack permissions." ;;
    *)   err "Unexpected HTTP $_auth_code from /myself. Check JIRA_DOMAIN is correct." ;;
  esac
  rm -f "$_auth_tmp"
  exit 1
fi
MY_ACCOUNT_ID=$(jq -r '.accountId' < "$_auth_tmp")
MY_DISPLAY=$(jq -r '.displayName // "unknown"' < "$_auth_tmp")
rm -f "$_auth_tmp"
printf "%s\n" "${GREEN}OK${RESET} (${MY_DISPLAY})"

# ─── Counters ─────────────────────────────────────────────────────────────
CREATED=0
REUSED=0

# ─── ADF description builder ──────────────────────────────────────────────
# build_adf <ac_text>
# Outputs a JSON object suitable for the Jira "description" field (ADF format).
build_adf() {
  local ac_text="$1"
  jq -n --arg ac "$ac_text" '{
    "type": "doc",
    "version": 1,
    "content": [
      {
        "type": "heading",
        "attrs": {"level": 2},
        "content": [{"type": "text", "text": "Acceptance Criteria"}]
      },
      {
        "type": "paragraph",
        "content": [{"type": "text", "text": $ac}]
      }
    ]
  }'
}

# ─── [1/3] Project check / create ─────────────────────────────────────────
printf "\n%s\n" "${BOLD}[1/3] Project${RESET}"

_proj_tmp=$(mktemp)
_proj_code=$(jira_req GET /project/DLTDEMO "" "$_proj_tmp")

case "$_proj_code" in
  200)
    skip "DLTDEMO project already exists, reusing"
    REUSED=$((REUSED + 1))
    ;;
  404)
    _proj_body=$(jq -n \
      --arg key  "DLTDEMO" \
      --arg name "DLT Demo" \
      --arg lead "$MY_ACCOUNT_ID" \
      '{
        key:             $key,
        name:            $name,
        projectTypeKey:  "software",
        projectTemplateKey: "com.pyxis.greenhopper.jira:gh-simplified-agility-scrum",
        leadAccountId:   $lead
      }')
    _proj_create_tmp=$(mktemp)
    _proj_create_code=$(jira_req POST /project "$_proj_body" "$_proj_create_tmp")
    if [[ "$_proj_create_code" != "201" ]]; then
      err "Failed to create project DLTDEMO (HTTP $_proj_create_code)"
      jq -r '.errors // .errorMessages // .' < "$_proj_create_tmp" >&2
      rm -f "$_proj_tmp" "$_proj_create_tmp"
      exit 1
    fi
    rm -f "$_proj_create_tmp"
    ok "Created project DLTDEMO"
    CREATED=$((CREATED + 1))
    ;;
  *)
    err "Unexpected HTTP $_proj_code checking project DLTDEMO"
    jq -r '.errors // .errorMessages // .' < "$_proj_tmp" >&2
    rm -f "$_proj_tmp"
    exit 1
    ;;
esac
rm -f "$_proj_tmp"

# ─── Issue helpers ─────────────────────────────────────────────────────────
# find_issue_by_summary <summary>
# Echoes the issue key if found (exact match), empty string if not found.
find_issue_by_summary() {
  local summary="$1"
  local _tmp; _tmp=$(mktemp)
  local _code
  # JQL exact-match (= not ~); client-side filter guards against fuzzy hits
  _code=$(jira_search "project=DLTDEMO AND summary=\"${summary}\"" "summary,key" "$_tmp")
  if [[ "$_code" != "200" ]]; then
    rm -f "$_tmp"
    printf ''
    return 0
  fi
  local found_key
  found_key=$(jq -r --arg s "$summary" \
    '.issues[] | select(.fields.summary == $s) | .key' < "$_tmp" | head -1)
  rm -f "$_tmp"
  printf '%s' "$found_key"
}

# create_issue <summary> <description_json>
# Echoes the new issue key on success; exits 1 on failure.
create_issue() {
  local summary="$1"
  local desc_json="$2"
  local body
  body=$(jq -n \
    --arg   proj    "DLTDEMO" \
    --arg   summary "$summary" \
    --argjson desc  "$desc_json" \
    '{
      fields: {
        project:     {key: $proj},
        summary:     $summary,
        description: $desc,
        issuetype:   {name: "Task"}
      }
    }')
  local _tmp; _tmp=$(mktemp)
  local _code
  _code=$(jira_req POST /issue "$body" "$_tmp")
  if [[ "$_code" != "201" ]]; then
    err "Failed to create issue '$summary' (HTTP $_code)"
    jq -r '.errors // .errorMessages // .' < "$_tmp" >&2
    rm -f "$_tmp"
    return 1
  fi
  local key
  key=$(jq -r '.key' < "$_tmp")
  rm -f "$_tmp"
  printf '%s' "$key"
}

# ─── [2/3] Issues ──────────────────────────────────────────────────────────
printf "\n%s\n" "${BOLD}[2/3] Issues${RESET}"

# ── Issue 1: Create bronze table A ─────────────────────────────────────────
SUMMARY_A="Create bronze table A"
AC_A="Create a DLT bronze streaming table reading from {volume_path}/customers.csv with schema: id (string), name (string), region (string), signup_date (string). Table must be created in the Unity Catalog sandbox and be queryable."

KEY_A=$(find_issue_by_summary "$SUMMARY_A")
if [[ -n "$KEY_A" ]]; then
  skip "$KEY_A already exists ($SUMMARY_A), reusing"
  REUSED=$((REUSED + 1))
else
  DESC_A=$(build_adf "$AC_A")
  KEY_A=$(create_issue "$SUMMARY_A" "$DESC_A") || exit 1
  ok "Created $KEY_A: $SUMMARY_A"
  CREATED=$((CREATED + 1))
fi

# ── Issue 2: Create bronze table B ─────────────────────────────────────────
SUMMARY_B="Create bronze table B"
AC_B="Create a DLT bronze streaming table reading from {volume_path}/orders.csv with schema: order_id (string), customer_id (string), amount (decimal), order_date (string). Table must be created in the Unity Catalog sandbox and be queryable."

KEY_B=$(find_issue_by_summary "$SUMMARY_B")
if [[ -n "$KEY_B" ]]; then
  skip "$KEY_B already exists ($SUMMARY_B), reusing"
  REUSED=$((REUSED + 1))
else
  DESC_B=$(build_adf "$AC_B")
  KEY_B=$(create_issue "$SUMMARY_B" "$DESC_B") || exit 1
  ok "Created $KEY_B: $SUMMARY_B"
  CREATED=$((CREATED + 1))
fi

# ── Issue 3: Create silver table C ─────────────────────────────────────────
SUMMARY_C="Create silver table C"

if [[ "$HARD_MODE" -eq 1 ]]; then
  # Intentionally broken: customerid (no underscore) triggers schema mismatch
  AC_C="Create a DLT silver materialized view joining bronze_a (customers) and bronze_b (orders) on customerid (no underscore), producing: customerid, total_orders (count), total_amount (sum of amount), last_order_date (max of order_date). Table must be queryable and row count must match distinct customerid count from bronze_a."
else
  AC_C="Create a DLT silver materialized view joining bronze_a (customers) and bronze_b (orders) on customer_id, producing: customer_id, total_orders (count), total_amount (sum of amount), last_order_date (max of order_date). Table must be queryable and row count must match distinct customer count from bronze_a."
fi

KEY_C=$(find_issue_by_summary "$SUMMARY_C")
if [[ -n "$KEY_C" ]]; then
  skip "$KEY_C already exists ($SUMMARY_C), reusing"
  REUSED=$((REUSED + 1))
else
  DESC_C=$(build_adf "$AC_C")
  KEY_C=$(create_issue "$SUMMARY_C" "$DESC_C") || exit 1
  ok "Created $KEY_C: $SUMMARY_C"
  CREATED=$((CREATED + 1))
fi

# ─── [3/3] Issue links (parallel) ─────────────────────────────────────────
printf "\n%s\n" "${BOLD}[3/3] Issue links${RESET}"

# Resolve the "Blocks" link type name for this Jira instance.
# Sets LINK_TYPE_NAME; falls back to auto-detecting from /issueLinkType.
LINK_TYPE_NAME="Blocks"

resolve_link_type() {
  local _tmp; _tmp=$(mktemp)
  local _code
  _code=$(jira_req GET /issueLinkType "" "$_tmp")
  if [[ "$_code" != "200" ]]; then
    rm -f "$_tmp"
    return 1
  fi
  # Prefer type whose outward description contains "blocks" (case-insensitive)
  local found
  found=$(jq -r '
    .issueLinkTypes[]
    | select(.outward | ascii_downcase | contains("blocks"))
    | .name
  ' < "$_tmp" | head -1)
  if [[ -z "$found" ]]; then
    # Fallback: type whose inward description contains "blocked"
    found=$(jq -r '
      .issueLinkTypes[]
      | select(.inward | ascii_downcase | contains("blocked"))
      | .name
    ' < "$_tmp" | head -1)
  fi
  rm -f "$_tmp"
  if [[ -n "$found" ]]; then
    LINK_TYPE_NAME="$found"
    return 0
  fi
  return 1
}

# link_exists <blocker_key> <blocked_key>
# Returns 0 if the "blocked by" link already exists, 1 otherwise.
link_exists() {
  local blocker="$1"
  local blocked="$2"
  local _tmp; _tmp=$(mktemp)
  local _code
  _code=$(jira_req GET "/issue/${blocked}?fields=issuelinks" "" "$_tmp")
  if [[ "$_code" != "200" ]]; then
    rm -f "$_tmp"
    return 1
  fi
  local found
  found=$(jq -r --arg blocker "$blocker" '
    .fields.issuelinks[]
    | select(
        (.type.inward | ascii_downcase | contains("block")) and
        .inwardIssue.key == $blocker
      )
    | .inwardIssue.key
  ' < "$_tmp" 2>/dev/null | head -1)
  rm -f "$_tmp"
  [[ -n "$found" ]]
}

# create_link_bg <inward_key> <outward_key> <result_file>
# Writes "created", "reused", or "error:<detail>" to result_file.
# Designed for background execution — never writes to stdout/stderr directly.
create_link_bg() {
  local inward="$1"   # blocker issue key
  local outward="$2"  # blocked issue key
  local result_file="$3"

  # Guard against unexpected set -e exits writing nothing to result_file
  trap 'printf "error:unexpected failure in link %s->%s" "'"$inward"'" "'"$outward"'" > "'"$result_file"'"' ERR

  # Idempotency: check if link already exists
  if link_exists "$inward" "$outward"; then
    printf 'reused' > "$result_file"
    return 0
  fi

  # Build request body
  local body
  body=$(jq -n \
    --arg type_name "$LINK_TYPE_NAME" \
    --arg inward    "$inward" \
    --arg outward   "$outward" \
    '{
      type:         {name: $type_name},
      inwardIssue:  {key: $inward},
      outwardIssue: {key: $outward}
    }')

  local _tmp; _tmp=$(mktemp)
  local _code
  _code=$(jira_req POST /issueLink "$body" "$_tmp")

  if [[ "$_code" == "201" || "$_code" == "200" ]]; then
    printf 'created' > "$result_file"
    rm -f "$_tmp"
    return 0
  fi

  # Check if this is a link type not found error — attempt fallback once
  local err_body
  err_body=$(cat "$_tmp")
  rm -f "$_tmp"

  if printf '%s' "$err_body" | grep -qi "link type\|No issue link type"; then
    if resolve_link_type; then
      body=$(jq -n \
        --arg type_name "$LINK_TYPE_NAME" \
        --arg inward    "$inward" \
        --arg outward   "$outward" \
        '{
          type:         {name: $type_name},
          inwardIssue:  {key: $inward},
          outwardIssue: {key: $outward}
        }')
      local _tmp2; _tmp2=$(mktemp)
      local _code2
      _code2=$(jira_req POST /issueLink "$body" "$_tmp2")
      if [[ "$_code2" == "201" || "$_code2" == "200" ]]; then
        printf 'created' > "$result_file"
        rm -f "$_tmp2"
        return 0
      fi
      local err_body2
      err_body2=$(cat "$_tmp2")
      rm -f "$_tmp2"
      printf 'error:HTTP %s (after fallback to "%s") — %s' \
        "$_code2" "$LINK_TYPE_NAME" "$err_body2" > "$result_file"
      return 1
    else
      printf 'error:could not resolve a "Blocks"-type link on this Jira instance' \
        > "$result_file"
      return 1
    fi
  fi

  printf 'error:HTTP %s — %s' "$_code" "$err_body" > "$result_file"
  return 1
}

# Spawn both link creations in parallel
LINK1_TMP=$(mktemp)
LINK2_TMP=$(mktemp)

(create_link_bg "$KEY_A" "$KEY_C" "$LINK1_TMP") \
  || printf 'error:unexpected subshell failure' > "$LINK1_TMP" &
PID1=$!

(create_link_bg "$KEY_B" "$KEY_C" "$LINK2_TMP") \
  || printf 'error:unexpected subshell failure' > "$LINK2_TMP" &
PID2=$!

wait "$PID1" || true
wait "$PID2" || true

# Process link 1 result
LINK1_RESULT=$(cat "$LINK1_TMP")
rm -f "$LINK1_TMP"
case "$LINK1_RESULT" in
  created) ok  "Created link: $KEY_A blocks $KEY_C"; CREATED=$((CREATED + 1)) ;;
  reused)  skip "Link $KEY_A → $KEY_C already exists, skipping"; REUSED=$((REUSED + 1)) ;;
  error:*) die "Failed to create link $KEY_A → $KEY_C: ${LINK1_RESULT#error:}" ;;
  *)       die "Failed to create link $KEY_A → $KEY_C: unknown result '${LINK1_RESULT}'" ;;
esac

# Process link 2 result
LINK2_RESULT=$(cat "$LINK2_TMP")
rm -f "$LINK2_TMP"
case "$LINK2_RESULT" in
  created) ok  "Created link: $KEY_B blocks $KEY_C"; CREATED=$((CREATED + 1)) ;;
  reused)  skip "Link $KEY_B → $KEY_C already exists, skipping"; REUSED=$((REUSED + 1)) ;;
  error:*) die "Failed to create link $KEY_B → $KEY_C: ${LINK2_RESULT#error:}" ;;
  *)       die "Failed to create link $KEY_B → $KEY_C: unknown result '${LINK2_RESULT}'" ;;
esac

# ─── Summary ──────────────────────────────────────────────────────────────
printf "\n%s\n" "${BOLD}Seeded: ${CREATED} created, ${REUSED} reused — DLTDEMO ready.${RESET}"
