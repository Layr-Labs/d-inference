import json
import os
from datetime import timedelta

import psycopg
import pytest
from psycopg.conninfo import conninfo_to_dict

from telemetry_archive.artifact import capture, read_artifact
from telemetry_archive.model import ArchiveError
from telemetry_archive.source import snapshot


@pytest.fixture
def database(window):
    dsn = os.environ.get("TEST_ARCHIVE_DATABASE_URL")
    if not dsn:
        pytest.skip("set TEST_ARCHIVE_DATABASE_URL to a disposable local archive_test database")
    params = conninfo_to_dict(dsn)
    assert params.get("host") in ("127.0.0.1", "localhost")
    assert params.get("dbname") == "archive_test"
    with psycopg.connect(dsn, autocommit=True) as conn:
        assert conn.execute("SELECT pg_is_in_recovery()").fetchone()[0] is False
        conn.execute("DROP TABLE IF EXISTS request_profiles")
        conn.execute("""CREATE TABLE request_profiles (
            id BIGINT PRIMARY KEY, created_at TIMESTAMPTZ NOT NULL,
            model TEXT, final_status TEXT, exact_numeric NUMERIC,
            payload JSONB, future_column TEXT, nullable_column TEXT
        )""")
        conn.execute("CREATE INDEX ON request_profiles(created_at)")
        for index in (1, 3, 90):
            conn.execute(
                "INSERT INTO request_profiles VALUES (%s,%s,'model','success',"
                "12345678901234567890.12345678901234567890,"
                '\'{"huge":9223372036854775807,"unicode":"☃"}\', \'future\', NULL)',
                (index, window.start + timedelta(microseconds=index)),
            )
    return dsn


def test_primary_is_refused_by_default(database, window, tmp_path):
    directory = tmp_path / "refused"
    with pytest.raises(ArchiveError, match="physical replica"):
        capture(database, window, directory)
    assert not (directory / "receipt.json").exists()


def test_real_postgres_capture_and_lossless_restore(database, window, tmp_path):
    import pyarrow.parquet as pq

    directory = tmp_path / "snapshot"
    receipt = capture(database, window, directory, require_replica=False)
    read_artifact(directory)
    assert receipt["stats"]["rows"] == 3
    assert "future_column" in {field["name"] for field in receipt["source"]["columns"]}
    with psycopg.connect(database, autocommit=True) as conn:
        for row in pq.read_table(directory / "data.parquet").to_pylist():
            equal = conn.execute(
                "SELECT to_jsonb(json_populate_record(NULL::request_profiles,%s::json))"
                " = to_jsonb(s) FROM request_profiles s WHERE id=%s",
                (row["row_json"], row["source_id"]),
            ).fetchone()[0]
            assert equal
        assert conn.execute("SELECT COUNT(*) FROM request_profiles").fetchone()[0] == 3


def test_one_snapshot_does_not_claim_late_commits(database, window):
    with snapshot(database, window, require_replica=False) as (metadata, count, pages):
        with psycopg.connect(database, autocommit=True) as writer:
            writer.execute(
                "INSERT INTO request_profiles(id,created_at) VALUES (2,%s)", (window.start,)
            )
        rows = [row for page in pages for row in page]
        assert metadata["read_only"] == "on"
        assert count == len(rows) == 3
        assert 2 not in [row[0] for row in rows]
    with snapshot(database, window, require_replica=False) as (_, count, pages):
        assert count == len([row for page in pages for row in page]) == 4


def test_query_failure_never_produces_success_receipt(database, window, tmp_path, monkeypatch):
    from telemetry_archive import artifact

    original = artifact.encode

    def interrupted(pages, *args):
        def failing_pages():
            yield next(pages)
            raise psycopg.OperationalError("simulated disconnect")

        return original(failing_pages(), *args)

    monkeypatch.setattr(artifact, "encode", interrupted)
    directory = tmp_path / "partial"
    with pytest.raises(psycopg.OperationalError):
        capture(database, window, directory, require_replica=False)
    assert not (directory / "receipt.json").exists()
    with psycopg.connect(database) as conn:
        assert conn.execute("SELECT COUNT(*) FROM request_profiles").fetchone()[0] == 3


def test_cli_does_not_print_database_credentials(monkeypatch, capsys):
    from telemetry_archive.cli import main

    monkeypatch.setenv(
        "ARCHIVE_DATABASE_URL", "postgresql://user:never-print-me@127.0.0.1:1/archive_test"
    )
    monkeypatch.setattr(
        "sys.argv",
        [
            "telemetry-archive",
            "capture",
            "--table",
            "request_profiles",
            "--start",
            "2026-09-01T00:00:00Z",
            "--end",
            "2026-09-01T00:01:00Z",
            "--directory",
            "/not-used",
        ],
    )
    monkeypatch.setattr(
        "telemetry_archive.cli.capture",
        lambda *a: (_ for _ in ()).throw(psycopg.OperationalError("never-print-me")),
    )
    assert main() == 1
    result = capsys.readouterr()
    assert "never-print-me" not in result.out + result.err
    assert json.loads(result.err)["error"] == "OperationalError"


def test_request_outcomes_preserves_nested_record_and_revision(database, window, tmp_path):
    from dataclasses import replace

    import pyarrow.parquet as pq

    with psycopg.connect(database, autocommit=True) as conn:
        conn.execute("DROP TABLE IF EXISTS request_outcomes")
        conn.execute(
            "CREATE TABLE request_outcomes (id BIGINT UNIQUE, "
            "coord_request_id TEXT PRIMARY KEY, received_at TIMESTAMPTZ NOT NULL, "
            "revision BIGINT NOT NULL, record JSONB NOT NULL)"
        )
        conn.execute(
            "INSERT INTO request_outcomes VALUES (7,'request',%s,3,"
            '\'{"model":"test","exact":1234567890123456789,"nested":[1,null]}\')',
            (window.start,),
        )
    target = replace(window, table="request_outcomes")
    receipt = capture(database, target, tmp_path / "outcomes", require_replica=False)
    assert receipt["stats"]["rows"] == 1
    raw = pq.read_table(tmp_path / "outcomes" / "data.parquet").to_pylist()[0]["row_json"]
    with psycopg.connect(database) as conn:
        assert conn.execute(
            "SELECT to_jsonb(json_populate_record(NULL::request_outcomes,%s::json))"
            " = to_jsonb(s) FROM request_outcomes s WHERE id=7",
            (raw,),
        ).fetchone()[0]
