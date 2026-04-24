# uc-volume-file-path

Unity Catalog Volume files are addressed as `/Volumes/<catalog>/<schema>/<volume>/<file>`. `databricks fs cp` accepts `dbfs:/Volumes/...` as destination; DLT pipelines use the same path without the `dbfs:` prefix.

## Instances

| Component | Files | Source |
|-----------|-------|--------|
| _unlinked_ |  | ticket-004 |

## Gotchas

_No gotchas recorded._

## Related Patterns

_No related patterns._

