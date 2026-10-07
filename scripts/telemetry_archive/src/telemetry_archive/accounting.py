"""Exact signed-integer reconciliation, independent of Parquet compression."""

import json

from .model import ArchiveError
from .tables import ACCOUNTING_FIELDS, ACCOUNTING_TEXT_FIELDS


def empty_totals(table):
    return dict.fromkeys(ACCOUNTING_FIELDS.get(table, ()), 0)


def add_row(totals, raw):
    if not totals:
        return
    record = json.loads(raw)
    for field in totals:
        value = record.get(field)
        if type(value) is not int or not -(2**63) <= value < 2**63:
            raise ArchiveError(f"accounting field {field} must be an exact signed integer")
        totals[field] += value


def serialized_totals(totals):
    # SUM(bigint) can exceed INT64. Decimal strings also avoid JSON float readers.
    return {field: str(value) for field, value in totals.items()}


def validate_totals(table, totals, rows):
    fields = ACCOUNTING_FIELDS.get(table)
    if fields is None:
        return
    # Pre-bonus receipts remain immutable and verify only their original totals.
    # New captures require the complete current source schema in source.snapshot.
    allowed = [set(fields)]
    if table == "provider_floor_draws":
        allowed.append(set(fields) - {"autopilot_bonus_micro_usd"})
    if not isinstance(totals, dict) or set(totals) not in allowed:
        raise ArchiveError("missing or unexpected accounting reconciliation fields")
    for value in totals.values():
        try:
            integer = int(value)
        except (TypeError, ValueError):
            raise ArchiveError("invalid accounting reconciliation total") from None
        if not isinstance(value, str) or str(integer) != value or abs(integer) > rows * 2**63:
            raise ArchiveError("invalid accounting reconciliation total")


def query_aggregates(table, fields=None):
    return [
        "CAST(COALESCE(SUM(CAST(JSON_VALUE(row_json, '$."
        + field
        + "') AS BIGNUMERIC)), 0) AS STRING) AS accounting_"
        + field
        for field in ACCOUNTING_FIELDS.get(table, ())
        if fields is None or field in fields
    ]


def query_projections(table):
    return [
        f"JSON_VALUE(r.row_json, '$.{field}') AS {field}"
        for field in ACCOUNTING_TEXT_FIELDS.get(table, ())
    ] + [
        (
            f"COALESCE(CAST(JSON_VALUE(r.row_json, '$.{field}') AS INT64), 0) AS {field}"
            if table == "provider_floor_draws" and field == "autopilot_bonus_micro_usd"
            else f"CAST(JSON_VALUE(r.row_json, '$.{field}') AS INT64) AS {field}"
        )
        for field in ACCOUNTING_FIELDS.get(table, ())
    ]
