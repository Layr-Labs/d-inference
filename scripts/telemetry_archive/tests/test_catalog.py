import pytest

from telemetry_archive.backfill_plan import identity, make_plan, window_key
from telemetry_archive.catalog import merge_files, verified_entries
from telemetry_archive.journal import Journal
from telemetry_archive.model import ArchiveError
from telemetry_archive.objects import upload
from telemetry_archive.publish import reader_sql

from .fake_storage import Client


def test_catalog_requires_verified_receipt_and_current_generation(artifact, window):
    directory, receipt = artifact
    client = Client()
    published = upload(directory, client, "archive-test", "us-east4")
    plan = make_plan([identity(window)])
    journal = Journal(client.bucket, plan["plan_id"])
    assert list(verified_entries(client.bucket, "archive-test", plan)) == []
    state = {
        "plan_id": plan["plan_id"],
        "window": identity(window),
        "copy_only": True,
        "retention_eligible": False,
        "status": "complete",
        "result": {
            "verified": True,
            "artifact_id": receipt["artifact_id"],
            "rows": receipt["stats"]["rows"],
            "parquet_bytes": receipt["stats"]["file_bytes"],
            "objects": {k: published[k] for k in ("data", "manifest")},
        },
    }
    journal.put("windows/" + window_key(window), state)
    entries = list(verified_entries(client.bucket, "archive-test", plan))
    assert entries[0]["row_count"] == receipt["stats"]["rows"]
    name = published["data"]["name"]
    raw, metadata, generation = client.bucket.objects[name]
    client.bucket.objects[name] = raw, metadata, generation + 1
    with pytest.raises(ArchiveError, match="changed"):
        list(verified_entries(client.bucket, "archive-test", plan))


def test_repeated_snapshots_do_not_duplicate_identical_files():
    entry = {"source_uri": "gs://b/a", "generation": "1", "observed_at": "2026-09-01T00:00:00Z"}
    later = dict(entry, observed_at="2026-09-02T00:00:00Z")
    assert merge_files([entry, later])[0]["observed_at"] == "2026-09-02T00:00:00.000000Z"
    assert len(merge_files([entry, later])) == 1
    with pytest.raises(ArchiveError):
        merge_files([entry, dict(later, generation="2")])


def test_reader_uses_observation_time_not_filename_to_resolve_updates():
    sql = reader_sql("archive-project", "telemetry_history", "request_outcomes", "a" * 16)
    assert "PARTITION BY r.source_id ORDER BY c.observed_at DESC" in sql
    assert "r._FILE_NAME = c.source_uri" in sql
    with pytest.raises(ArchiveError):
        reader_sql("archive-project", "billing", "request_outcomes", "a" * 16)
