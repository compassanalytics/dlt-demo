# Knowledge Index

## Insights

- [Gotchas](insights/gotchas.md) — _Generated index of all gotchas across components._

## Patterns

- [Seed Csv Outer Join Design](patterns/seed-csv-outer-join-design.md) — Seed data for demos should deliberately over-provision zero-order customers (14 instead of the spec-required 3) to make outer-join behavior visible. Same for multi-order customers — cluster them at low IDs (1, 2, 3) for presenter clarity.
- [Single Source Volume Paths Doc](patterns/single-source-volume-paths-doc.md) — Create `docs/volume-paths.md` once at the first ticket that lands a Volume; all downstream tickets (pipelines, teardown, runbooks) reference it instead of re-deriving the path. Keeps catalog/schema/volume name changes a one-line edit.
- [Uc Volume File Path](patterns/uc-volume-file-path.md) — Unity Catalog Volume files are addressed as `/Volumes/<catalog>/<schema>/<volume>/<file>`. `databricks fs cp` accepts `dbfs:/Volumes/...` as destination; DLT pipelines use the same path without the `dbfs:` prefix.
- [Volume Create Cli Positional](patterns/volume-create-cli-positional.md) — `databricks volumes create` takes 4 positional args: CATALOG SCHEMA NAME VOLUME_TYPE. VOLUME_TYPE must be `MANAGED` or `EXTERNAL` — it is NOT a `--volume-type` flag. Confirmed against CLI v0.298.0.
- [Volume Create Idempotency Grep](patterns/volume-create-idempotency-grep.md) — For `databricks volumes create`, capture stdout+stderr and grep `-qiE 'already exists|ALREADY_EXISTS'` to distinguish "benign already-exists" from real failures. Print + `exit 1` on anything else. Works with `set -euo pipefail` because the `if !` check consumes the non-zero exit.
