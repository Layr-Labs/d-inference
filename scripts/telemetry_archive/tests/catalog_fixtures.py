"""Archive catalog rows for coverage and publication tests."""


def coverage_row(**changes):
    return {
        "table_name": "request_outcomes",
        "plan_id": "plan-a",
        "window_start": "2026-09-01T00:00:00Z",
        "window_end": "2026-09-01T01:00:00Z",
        "source_uri": "gs://archive-bucket/data/v1/empty.parquet",
        "generation": "1",
        "observed_at": "2026-09-03T00:00:00Z",
        "row_count": 0,
        "parquet_bytes": 42,
        **changes,
    }
