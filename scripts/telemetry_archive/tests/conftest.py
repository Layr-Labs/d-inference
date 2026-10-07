import hashlib
import json
from datetime import UTC, datetime, timedelta

import pytest

from telemetry_archive.artifact import json_bytes
from telemetry_archive.codec import encode
from telemetry_archive.model import Window, stamp


@pytest.fixture
def window():
    start = datetime(2026, 9, 1, tzinfo=UTC)
    return Window("request_profiles", start, start + timedelta(minutes=5), page_rows=2)


@pytest.fixture
def rows(window):
    result = []
    for index in (1, 3, 900):  # Sparse IDs must not be mistaken for missing rows.
        when = window.start + timedelta(microseconds=index)
        raw = json.dumps(
            {
                "id": index,
                "created_at": stamp(when),
                "model": "test/model",
                "provider_id": None,
                "final_status": "success",
                "new_unprojected_column": {"nested": ["こんにちは", None, 9223372036854775807]},
                "exact_numeric": "12345678901234567890.12345678901234567890",
            },
            ensure_ascii=False,
        )
        result.append((index, when, raw))
    return result


@pytest.fixture
def artifact(tmp_path, window, rows):
    directory = tmp_path / "capture"
    directory.mkdir()
    stats = encode([rows[:2], rows[2:]], directory / "data.parquet", window, len(rows))
    receipt = {
        "format_version": 1,
        "copy_only": True,
        "retention_eligible": False,
        "table": window.table,
        "start": stamp(window.start),
        "end": stamp(window.end),
        "source": {
            "in_recovery": True,
            "read_only": "on",
            "columns": [],
            "observed_at": stamp(window.end),
        },
        "stats": stats,
    }
    receipt["artifact_id"] = hashlib.sha256(json_bytes(receipt)).hexdigest()
    (directory / "receipt.json").write_bytes(json_bytes(receipt))
    return directory, receipt
