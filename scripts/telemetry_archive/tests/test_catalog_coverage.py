"""Window coverage must not be lost when immutable data files are shared."""

import pytest

from telemetry_archive.catalog import merge_coverage, merge_files
from telemetry_archive.model import ArchiveError

from .catalog_fixtures import coverage_row


@pytest.mark.parametrize("mode", ["time", "id"])
def test_distinct_empty_windows_keep_coverage_but_share_one_file(mode):
    first = coverage_row()
    second = coverage_row(window_start="2026-09-01T01:00:00Z", window_end="2026-09-01T02:00:00Z")
    if mode == "id":
        first.update(window_start=None, window_end=None, id_start=1, id_end=1001)
        second.update(window_start=None, window_end=None, id_start=1001, id_end=2001)
    rows = merge_coverage([first, second, first])
    assert len(rows) == 2
    assert len(merge_files(rows)) == 1
    assert sum(r["parquet_bytes"] for r in merge_files(rows)) == 42
    assert rows == merge_coverage([second, first])


def test_retries_choose_latest_observation_within_each_plan_window():
    first = coverage_row()
    later = coverage_row(
        observed_at="2026-09-04T00:00:00Z", source_uri="gs://archive-bucket/data/v1/new.parquet"
    )
    assert merge_coverage([later, first])[0]["source_uri"] == later["source_uri"]
    refresh_plan = coverage_row(plan_id="plan-b")
    assert len(merge_coverage([first, refresh_plan])) == 2
    assert len(merge_files(merge_coverage([first, refresh_plan]))) == 1


def test_coverage_rejects_generation_or_observation_conflicts():
    first = coverage_row()
    with pytest.raises(ArchiveError, match="generation conflict"):
        merge_coverage([first, coverage_row(generation="2")])
    with pytest.raises(ArchiveError, match="conflicting simultaneous"):
        merge_coverage(
            [first, coverage_row(source_uri="gs://archive-bucket/data/v1/other.parquet")]
        )
