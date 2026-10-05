import hashlib
import json
from datetime import timedelta

import pytest
from psycopg.conninfo import conninfo_to_dict

from telemetry_archive.artifact import json_bytes
from telemetry_archive.backfill import BackfillIncomplete, Runner, SplitWindow
from telemetry_archive.backfill_job import database_url
from telemetry_archive.backfill_plan import (
    children,
    identity,
    make_plan,
    validate_plan,
    window_key,
    windows,
)
from telemetry_archive.journal import CONTROL_OBJECT_MAX_BYTES, Journal
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


def test_live_state_plan_and_duplicates_rejected(plan):
    for ranges in ([dict(plan["ranges"][0], table="balances")], plan["ranges"] * 2):
        with pytest.raises(ArchiveError):
            make_plan(ranges)


@pytest.mark.parametrize(
    "version,ranges",
    [
        (
            1,
            [
                {
                    "table": "request_profiles",
                    "start": "2026-09-01T00:00:00.000000Z",
                    "end": "2026-09-01T01:00:00.000000Z",
                }
            ],
        ),
        (2, [{"table": "ledger_entries", "id_start": 1, "id_end": 200002}]),
    ],
)
def test_plan_generations_preserve_legacy_identities(version, ranges):
    legacy = {"version": version, "copy_only": True, "ranges": ranges}
    legacy["plan_id"] = hashlib.sha256(json_bytes(legacy)).hexdigest()
    assert make_plan(ranges) == legacy
    assert make_plan(ranges, capture_generation=None) == legacy
    validate_plan(legacy)

    generated = make_plan(ranges, capture_generation="manual_2026-09-02")
    assert generated["version"] == 3
    assert generated["capture_generation"] == "manual_2026-09-02"
    assert generated["plan_id"] != legacy["plan_id"]
    assert generated == make_plan(ranges, capture_generation="manual_2026-09-02")
    assert list(windows(generated)) == list(windows(legacy))
    validate_plan(generated)
    for changes in (
        {"capture_generation": "another"},
        {"capture_generation": None},
        {"version": version},
        {"plan_id": legacy["plan_id"]},
    ):
        with pytest.raises(ArchiveError):
            validate_plan({**generated, **changes})
    with pytest.raises(ArchiveError):
        validate_plan({**legacy, "capture_generation": "manual_2026-09-02"})


@pytest.mark.parametrize(
    "value", ["", "a" * 65, "../a", "a/b", "a b", "a\n", "\u00e9", "_a", 1, True]
)
def test_invalid_capture_generations_are_rejected(plan, value):
    with pytest.raises(ArchiveError, match="capture generation"):
        make_plan(plan["ranges"], capture_generation=value)
    with pytest.raises(ArchiveError, match="capture generation"):
        validate_plan({**plan, "version": 3, "capture_generation": value})


def test_capture_generation_recaptures_mutable_ranges_but_resumes_once(plan):
    bucket = Bucket()
    calls = []

    def capture(window):
        calls.append(window)
        return {**process(window), "rows": len(calls)}

    previous_ids = set()
    for generation in (None, "first", "second", "a" * 64):
        current = make_plan(plan["ranges"], capture_generation=generation)
        assert current["plan_id"] not in previous_ids
        previous_ids.add(current["plan_id"])
        journal = Journal(bucket, current["plan_id"])
        before = len(calls)
        with pytest.raises(BackfillIncomplete):
            runner(current, journal, capture, max_new_windows=1).run()
        summary = runner(current, journal, capture).run()
        assert len(calls) == before + 3
        assert summary["tables"]["request_profiles"]["rows"] == sum(range(before + 1, before + 4))
        stored = dict(bucket.objects)
        assert runner(current, journal, lambda w: pytest.fail("already copied")).run() == summary
        assert bucket.objects == stored


def test_completed_windows_are_not_exported_again(plan):
    journal = Journal(Bucket(), plan["plan_id"])
    first = runner(plan, journal, max_new_windows=3).run()
    stored = dict(journal.bucket.objects)
    second = runner(plan, journal, lambda w: pytest.fail("already copied"), max_new_windows=1).run()
    assert first == second
    assert journal.bucket.objects == stored
    assert first["tables"]["request_profiles"]["rows"] == 7200
    data = [process(w)["objects"]["data"] for w in windows(plan)]
    assert journal.get("catalogs/request_profiles") == {
        "plan_id": plan["plan_id"],
        "table": "request_profiles",
        "copy_only": True,
        "rows": 7200,
        "files": sorted(data, key=lambda item: item["name"]),
    }
    digest = hashlib.sha256()
    for window in windows(plan):
        digest.update(json_bytes(journal.get("windows/" + window_key(window))))
    assert first == {
        "plan_id": plan["plan_id"],
        "complete": True,
        "copy_only": True,
        "retention_eligible": False,
        "windows": 3,
        "checkpoint_sha256": digest.hexdigest(),
        "tables": {"request_profiles": {"rows": 7200, "parquet_bytes": 300, "windows": 3}},
    }


def test_year_catalog_is_bounded_and_resumes_partial_finalization(monkeypatch):
    plan = make_plan(
        [
            {
                "table": "request_profiles",
                "start": "2025-09-01T00:00:00Z",
                "end": "2026-09-01T00:00:00Z",
            }
        ]
    )
    journal = Journal(Bucket(), plan["plan_id"])
    expected_files = []

    def capture(window):
        result = process(window)
        digest = window_key(window)
        data = {
            "name": f"data/v1/{window.table}/{window.partition}/{digest}.parquet",
            "generation": 1234567890123456,
            "sha256": digest,
            "bytes": 100,
        }
        expected_files.append(data)
        return {**result, "objects": {"data": data}}

    put = journal.put

    def interrupt(key, value):
        if key.endswith("/shards/000001"):
            raise RuntimeError("interrupted catalog")
        return put(key, value)

    monkeypatch.setattr(journal, "put", interrupt)
    with pytest.raises(RuntimeError, match="interrupted catalog"):
        runner(plan, journal, capture, max_new_windows=8760).run()
    assert len(expected_files) == 8760
    assert journal.get("catalogs/request_profiles/shards/000000") is not None
    assert journal.get("catalogs/request_profiles") is None
    assert journal.get("summary") is None
    checkpoint_objects = dict(journal.bucket.objects)

    monkeypatch.setattr(journal, "put", put)
    summary = runner(
        plan, journal, lambda w: pytest.fail("already copied"), max_new_windows=1
    ).run()
    assert summary["windows"] == 8760
    assert summary["tables"]["request_profiles"] == {
        "rows": 365 * 86400,
        "parquet_bytes": 876000,
        "windows": 8760,
    }
    catalog = journal.get("catalogs/request_profiles")
    assert catalog["format_version"] == 2 and catalog["file_count"] == 8760
    assert catalog["rows"] == 365 * 86400
    files = []
    for index, reference in enumerate(catalog["shards"]):
        assert reference["key"] == f"catalogs/request_profiles/shards/{index:06d}"
        shard = journal.get(reference["key"])
        assert reference["sha256"] == hashlib.sha256(json_bytes(shard)).hexdigest()
        assert reference["file_count"] == len(shard["files"])
        files.extend(shard["files"])
    assert files == sorted(expected_files, key=lambda item: item["name"])
    legacy_catalog = {key: catalog[key] for key in ("plan_id", "table", "copy_only", "rows")}
    assert len(json_bytes({**legacy_catalog, "files": files})) > CONTROL_OBJECT_MAX_BYTES
    assert all(
        len(raw) <= CONTROL_OBJECT_MAX_BYTES for raw, _, _ in journal.bucket.objects.values()
    )
    assert all(journal.bucket.objects[key] == value for key, value in checkpoint_objects.items())
    completed = dict(journal.bucket.objects)
    assert runner(plan, journal, lambda w: pytest.fail("already copied")).run() == summary
    assert journal.bucket.objects == completed


def test_elapsed_budget_stops_saved_checkpoint_traversal_and_resumes(plan):
    journal = Journal(Bucket(), plan["plan_id"])
    seed = runner(plan, journal)
    for window in windows(plan):
        list(seed.visit(window))
    stored = dict(journal.bucket.objects)
    now, checked = [0], []

    def saved_check(result):
        checked.append(result)
        now[0] += 2

    with pytest.raises(BackfillIncomplete, match="execution budget"):
        Runner(
            plan,
            journal,
            lambda w: pytest.fail("already copied"),
            saved_check=saved_check,
            max_seconds=1,
            max_new_windows=1,
            monotonic=lambda: now[0],
        ).run()
    assert len(checked) == 1
    assert journal.bucket.objects == stored
    assert journal.get("summary") is None
    assert runner(plan, journal, lambda w: pytest.fail("already copied")).run()["windows"] == 3


def test_elapsed_budget_stops_finalization_after_catalog_write(plan, monkeypatch):
    journal = Journal(Bucket(), plan["plan_id"])
    now = [0]
    put = journal.put

    def slow_catalog(key, value):
        result = put(key, value)
        if key.startswith("catalogs/"):
            now[0] += 2
        return result

    monkeypatch.setattr(journal, "put", slow_catalog)
    with pytest.raises(BackfillIncomplete):
        runner(plan, journal, max_seconds=1, monotonic=lambda: now[0]).run()
    assert journal.get("catalogs/request_profiles") is not None
    assert journal.get("summary") is None
    assert runner(plan, journal, lambda w: pytest.fail("already copied")).run()["windows"] == 3


def test_elapsed_budget_preserves_finished_capture_before_stopping(plan):
    plan = make_plan([identity(next(windows(plan)))])
    journal = Journal(Bucket(), plan["plan_id"])
    now = [0]

    def slow_capture(window):
        now[0] += 2
        return process(window)

    with pytest.raises(BackfillIncomplete):
        runner(plan, journal, slow_capture, max_seconds=1, monotonic=lambda: now[0]).run()
    assert journal.get("windows/" + window_key(next(windows(plan))))["status"] == "complete"
    assert journal.get("summary") is None
    assert runner(plan, journal, lambda w: pytest.fail("already copied")).run()["windows"] == 1


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
