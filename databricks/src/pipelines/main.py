# DLT pipeline entrypoint.
#
# The bundle's libraries glob (`../src/pipelines/**` in
# databricks/resources/dltdemo_pipeline.pipeline.yml) already registers every
# .py file in this directory, so each dataset module is loaded independently
# by the DLT runtime. This file is kept as an explicit entrypoint for clarity
# and to satisfy the ticket-005 spec requirement that a main.py exists and
# references all three dataset modules.
from . import bronze_a, bronze_b, silver_c  # noqa: F401
