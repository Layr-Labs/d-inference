from types import SimpleNamespace

import pytest

from telemetry_archive.model import ArchiveError, utc
from telemetry_archive.queries import verify_query


class Client:
    def __init__(self, receipt):
        stats = receipt["stats"]
        self.result = {key: stats[key] for key in ("min_id", "max_id", "first_time", "last_time")}
        self.result.update(
            row_count=stats["rows"], distinct_ids=stats["rows"], invalid_hashes=0, outside_window=0
        )
        for field in ("first_time", "last_time"):
            self.result[field] = utc(self.result[field]) if self.result[field] else None

    def query(self, query, job_config, location):
        assert "SHA256(row_json)" in query
        assert job_config.maximum_bytes_billed == 1024**3
        assert job_config.use_query_cache is False
        external = job_config.table_definitions["archive_snapshot"].to_api_repr()
        assert external["sourceUris"] == ["gs://archive-test/data.parquet"]
        assert job_config.use_legacy_sql is False
        assert location == "us-east4"
        return SimpleNamespace(
            result=lambda **kwargs: [self.result],
            job_id="test-job",
            total_bytes_processed=100,
            total_bytes_billed=100,
        )


def test_bigquery_matches_snapshot_without_creating_dataset(artifact):
    _, receipt = artifact
    published = {
        "snapshot": receipt,
        "location": "us-east4",
        "bucket": "archive-test",
        "manifest": {"name": "manifest.txt"},
        "data": {"name": "data.parquet"},
    }
    assert verify_query(Client(receipt), published)["verified"] is True


def test_bigquery_empty_window(artifact):
    _, receipt = artifact
    receipt["stats"].update(rows=0, min_id=None, max_id=None, first_time=None, last_time=None)
    published = {
        "snapshot": receipt,
        "location": "us-east4",
        "bucket": "archive-test",
        "manifest": {"name": "manifest.txt"},
        "data": {"name": "data.parquet"},
    }
    assert verify_query(Client(receipt), published)["result"]["row_count"] == 0


@pytest.mark.parametrize(
    "field", ["row_count", "distinct_ids", "invalid_hashes", "outside_window", "max_id"]
)
def test_bigquery_disagreement_fails(artifact, field):
    _, receipt = artifact
    client = Client(receipt)
    client.result[field] += 1
    published = {
        "snapshot": receipt,
        "location": "us-east4",
        "bucket": "archive-test",
        "manifest": {"name": "manifest.txt"},
        "data": {"name": "data.parquet"},
    }
    with pytest.raises(ArchiveError):
        verify_query(client, published)
