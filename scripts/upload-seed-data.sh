#!/usr/bin/env bash
# upload-seed-data.sh
# Uploads seed CSVs to Unity Catalog Volume: sandbox.dltdemo.raw
#
# Volume file paths (for DLT pipeline references):
#   /Volumes/sandbox/dltdemo/raw/customers.csv
#   /Volumes/sandbox/dltdemo/raw/orders.csv
#
# Requires:
#   - databricks CLI installed (tested against v0.298.0)
#   - profile "julien-compass" configured with a valid token
#     (refresh with: databricks auth login --profile julien-compass)
#   - catalog "sandbox" and schema "dltdemo" must already exist
#     (created by the bundle-scaffold ticket #003)
#   - principal must have CREATE VOLUME on sandbox.dltdemo
#
# Idempotent: safe to run multiple times. Fails loudly (non-zero exit) on any
# Databricks CLI error so expired auth does not silently skip the upload.

set -euo pipefail

PROFILE="julien-compass"
CATALOG="sandbox"
SCHEMA="dltdemo"
VOLUME="raw"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_DIR="$SCRIPT_DIR/../databricks/src/seed_data"

echo "[upload-seed-data] Ensuring volume ${CATALOG}.${SCHEMA}.${VOLUME} exists..."
# volumes create is positional: CATALOG SCHEMA NAME VOLUME_TYPE
# If the volume already exists the CLI returns non-zero with a clear message;
# we tolerate that one specific case and continue, but surface anything else.
if ! create_out="$(databricks volumes create "$CATALOG" "$SCHEMA" "$VOLUME" MANAGED --profile "$PROFILE" 2>&1)"; then
  if echo "$create_out" | grep -qiE 'already exists|ALREADY_EXISTS'; then
    echo "[upload-seed-data] Volume already exists, continuing."
  else
    echo "[upload-seed-data] ERROR creating volume:" >&2
    echo "$create_out" >&2
    exit 1
  fi
else
  echo "[upload-seed-data] Volume created."
fi

DEST_ROOT="dbfs:/Volumes/${CATALOG}/${SCHEMA}/${VOLUME}"

echo "[upload-seed-data] Uploading customers.csv -> ${DEST_ROOT}/customers.csv"
databricks fs cp "${SEED_DIR}/customers.csv" "${DEST_ROOT}/customers.csv" \
  --overwrite --profile "$PROFILE"

echo "[upload-seed-data] Uploading orders.csv -> ${DEST_ROOT}/orders.csv"
databricks fs cp "${SEED_DIR}/orders.csv" "${DEST_ROOT}/orders.csv" \
  --overwrite --profile "$PROFILE"

echo "[upload-seed-data] Done. Files available at ${DEST_ROOT}/"
