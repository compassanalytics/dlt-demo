# volume-create-idempotency-grep

For `databricks volumes create`, capture stdout+stderr and grep `-qiE 'already exists|ALREADY_EXISTS'` to distinguish "benign already-exists" from real failures. Print + `exit 1` on anything else. Works with `set -euo pipefail` because the `if !` check consumes the non-zero exit.

## Instances

| Component | Files | Source |
|-----------|-------|--------|
| _unlinked_ |  | ticket-004 |

## Gotchas

_No gotchas recorded._

## Related Patterns

_No related patterns._

