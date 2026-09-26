import json
from datetime import timedelta

import pytest
from psycopg.conninfo import conninfo_to_dict

from telemetry_archive.backfill import BackfillIncomplete, Runner, SplitWindow
from telemetry_archive.backfill_job import database_url
from telemetry_archive.backfill_plan import children, identity, make_plan, window_key, windows
from telemetry_archive.journal import Journal
from telemetry_archive.model import ArchiveError

from .fake_storage import Bucket


@pytest.fixture
def plan():
    return make_plan(
        [
            {
                "table": "request_profiles",
                "start": "2026-09-01T23:30:00Z",
                "end": "2026-09-02T01:30:00Z",
            }
        ]
    )


def process(window):
    return {
        "verified": True,
        "rows": int((window.end - window.start).total_seconds()),
        "parquet_bytes": 100,
        "objects": {"data": {"name": "data/" + window_key(window), "generation": 1}},
    }


def runner(plan, journal, fn=process, **kwargs):
    return Runner(plan, journal, fn, saved_check=lambda state: None, **kwargs)


def test_plan_has_exact_coverage_at_midnight(plan):
    intervals = list(windows(plan))
    assert len(intervals) == 3
    assert all(a.end == b.start for a, b in zip(intervals, intervals[1:], strict=False))
    assert sum((w.end - w.start).total_seconds() for w in intervals) == 7200


def test_financial_plan_and_duplicates_rejected(plan):
    for ranges in ([dict(plan["ranges"][0], table="ledger_entries")], plan["ranges"] * 2):
        with pytest.raises(ArchiveError):
            make_plan(ranges)


def test_completed_windows_are_not_exported_again(plan):
    journal = Journal(Bucket(), plan["plan_id"])
    first = runner(plan, journal).run()
    second = runner(plan, journal, lambda w: pytest.fail("already copied")).run()
    assert first == second
    assert first["tables"]["request_profiles"]["rows"] == 7200
    assert len(journal.get("catalogs/request_profiles")["files"]) == 3


def test_interrupted_run_resumes_without_claiming_complete(plan):
    journal = Journal(Bucket(), plan["plan_id"])
    with pytest.raises(BackfillIncomplete):
        runner(plan, journal, max_new_windows=1).run()
    assert journal.get("summary") is None
    calls = []
    result = runner(plan, journal, lambda w: calls.append(w) or process(w)).run()
    assert result["complete"] and len(calls) == 2


def test_persisted_split_survives_restart_without_overlap(plan):
    journal = Journal(Bucket(), plan["plan_id"])

    def split(window):
        if window.end - window.start > timedelta(minutes=20):
            raise SplitWindow()
        return process(window)

    with pytest.raises(BackfillIncomplete):
        runner(plan, journal, split, max_new_windows=2).run()
    assert journal.get("summary") is None
    result = runner(plan, journal, split).run()
    assert result["tables"]["request_profiles"]["rows"] == 7200
    assert result["windows"] == 8


def test_unverified_or_failed_upload_never_gets_checkpoint(plan):
    for fn in (
        lambda w: {"verified": False},
        lambda w: (_ for _ in ()).throw(RuntimeError("upload")),
    ):
        journal = Journal(Bucket(), plan["plan_id"])
        with pytest.raises((ArchiveError, RuntimeError)):
            runner(plan, journal, fn).run()
        assert journal.get("summary") is None
        assert not journal.bucket.objects


def test_high_replica_lag_preserves_source_and_progress(plan):
    journal = Journal(Bucket(), plan["plan_id"])

    def pause():
        raise BackfillIncomplete("replica lag")

    with pytest.raises(BackfillIncomplete):
        runner(plan, journal, lambda w: pytest.fail("must not read"), ready=pause).run()
    assert journal.get("summary") is None


def test_concurrent_split_wins_over_overlapping_parent_copy(plan):
    journal = Journal(Bucket(), plan["plan_id"])
    first_window = next(windows(plan))
    left, _ = children(first_window)

    def concurrent(window):
        if window == first_window:
            journal.put(
                "windows/" + window_key(window),
                {
                    "plan_id": plan["plan_id"],
                    "window": identity(window),
                    "copy_only": True,
                    "retention_eligible": False,
                    "status": "split",
                    "middle": identity(left)["end"],
                },
            )
        return process(window)

    result = runner(plan, journal, concurrent).run()
    assert result["windows"] == 4
    assert result["tables"]["request_profiles"]["rows"] == 7200


def test_modified_saved_object_prevents_summary(plan):
    journal = Journal(Bucket(), plan["plan_id"])
    with pytest.raises(BackfillIncomplete):
        runner(plan, journal, max_new_windows=1).run()

    def changed(state):
        raise ArchiveError("generation changed")

    with pytest.raises(ArchiveError):
        Runner(plan, journal, process, saved_check=changed).run()
    assert journal.get("summary") is None


def test_mounted_credentials_are_bound_to_expected_instance(tmp_path, monkeypatch):
    path = tmp_path / "access.json"
    path.write_text(
        json.dumps(
            {
                "connection_name": "project:us-east4:replica",
                "username": "reader",
                "password": "p'word",
                "database": "test",
            }
        )
    )
    monkeypatch.delenv("ARCHIVE_DATABASE_URL", raising=False)
    monkeypatch.setenv("ARCHIVE_ACCESS_FILE", str(path))
    monkeypatch.setenv("ARCHIVE_EXPECTED_INSTANCE", "project:us-east4:replica")
    conn = conninfo_to_dict(database_url())
    assert conn["host"] == "/cloudsql/project:us-east4:replica"
    assert conn["password"] == "p'word"
    monkeypatch.setenv("ARCHIVE_EXPECTED_INSTANCE", "project:us-east4:primary")
    with pytest.raises(ArchiveError):
        database_url()
