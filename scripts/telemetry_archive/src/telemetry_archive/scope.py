"""Keep accounting archives separate from telemetry destinations and grants."""

from .model import ArchiveError
from .tables import ACCOUNTING_FIELDS, TABLES


def table_scope(tables):
    scopes = set()
    for table in tables:
        if table not in TABLES:
            raise ArchiveError("unsupported archive table")
        scopes.add("accounting" if table in ACCOUNTING_FIELDS else "telemetry")
    if len(scopes) != 1:
        raise ArchiveError("accounting and telemetry require separate plans and destinations")
    return scopes.pop()


def require_bucket_scope(bucket, tables):
    scope = table_scope(tables)
    label = (getattr(bucket, "labels", None) or {}).get("archive-scope")
    if scope == "accounting" and label != "accounting":
        raise ArchiveError(
            "accounting requires a dedicated bucket labeled archive-scope=accounting"
        )
    if scope == "telemetry" and label == "accounting":
        raise ArchiveError("telemetry cannot use the accounting archive bucket")


def require_dataset_scope(dataset, tables):
    if not dataset.startswith(table_scope(tables) + "_"):
        raise ArchiveError("BigQuery dataset does not match the archive data scope")
