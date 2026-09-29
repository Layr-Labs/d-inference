"""Publication separates exact source-window coverage from unique scan files."""

from types import SimpleNamespace

import pytest
from google.api_core.exceptions import NotFound
from google.cloud import bigquery

from telemetry_archive import publish as publisher
from telemetry_archive.backfill_plan import make_plan
from telemetry_archive.model import utc

from .catalog_fixtures import coverage_row


class Job:
    def __init__(self, rows=()):
        self.rows = rows

    def result(self, timeout):
        return self.rows


class BigQuery:
    def __init__(self, prior):
        self.prior = prior
        self.tables, self.loaded, self.statements = {}, [], []

    def get_dataset(self, _):
        return SimpleNamespace(location="us-east4")

    def get_table(self, name):
        if name.endswith(".archive_coverage"):
            return SimpleNamespace()
        if name not in self.tables:
            raise NotFound(name)
        return self.tables[name]

    def create_table(self, table, exists_ok):
        key = f"{table.project}.{table.dataset_id}.{table.table_id}"
        schema = (
            [bigquery.SchemaField(*field) for field in publisher.FILE_SCHEMA]
            if table.external_data_configuration
            else table.schema
        )
        self.tables.setdefault(
            key,
            SimpleNamespace(
                description=table.description,
                labels=table.labels,
                num_rows=0,
                external_data_configuration=table.external_data_configuration,
                schema=schema,
            ),
        )

    def load_table_from_json(self, rows, name, job_config):
        assert job_config.write_disposition == "WRITE_EMPTY"
        self.loaded = rows
        self.tables[name].num_rows = len(rows)
        return Job()

    def query(self, sql, job_config=None):
        self.statements.append(sql)
        return Job(self.prior if sql.startswith("SELECT *") else [])


def test_publisher_recovers_empty_window_coverage_and_deduplicates_manifest(monkeypatch):
    plan = make_plan(
        [
            {
                "table": "request_outcomes",
                "start": "2026-09-01T00:00:00Z",
                "end": "2026-09-01T02:00:00Z",
            }
        ]
    )
    first = coverage_row(plan_id=plan["plan_id"])
    second = coverage_row(
        plan_id=plan["plan_id"],
        window_start="2026-09-01T01:00:00Z",
        window_end="2026-09-01T02:00:00Z",
    )
    # The previous file-only catalog retained just the last of two empty hours.
    prior = dict(second)
    for field in ("observed_at", "window_start", "window_end"):
        prior[field] = utc(prior[field])
    client = BigQuery([prior])
    bucket = SimpleNamespace(labels={}, get_blob=lambda *a, **k: SimpleNamespace(generation="1"))
    monkeypatch.setattr(publisher.cloud, "storage_client", lambda *_: object())
    monkeypatch.setattr(publisher.cloud, "bigquery_client", lambda *_: client)
    monkeypatch.setattr(publisher, "archive_bucket", lambda *_: bucket)
    monkeypatch.setattr(publisher, "read_json", lambda *_: plan)
    monkeypatch.setattr(publisher, "verified_entries", lambda *_: iter([first, second]))
    manifests = {}

    def save_manifest(_bucket, name, path, **_):
        manifests[name] = path.read_text()

    monkeypatch.setattr(publisher, "put_verified", save_manifest)
    args = SimpleNamespace(
        project="archive-test",
        dataset="telemetry_history",
        bucket="archive-bucket",
        location="us-east4",
        plan_ids=[plan["plan_id"]],
    )
    result = publisher.publish(args)
    assert result["coverage_format"] == 2
    assert result["tables"] == [
        {"table": "request_outcomes", "verified_windows": 2, "data_files": 1, "snapshot_rows": 0}
    ]
    assert len(client.loaded) == 2
    assert len(manifests) == 1
    assert list(manifests.values()) == [first["source_uri"] + "\n"]
    assert ".archive_coverage` AS SELECT" in client.statements[-1]
    assert publisher.publish(args)["catalog_version"] == result["catalog_version"]


@pytest.mark.parametrize("mismatch", ["manifest", "schema"])
def test_publisher_rejects_reused_external_table_mismatch(monkeypatch, mismatch):
    plan = make_plan(
        [
            {
                "table": "request_outcomes",
                "start": "2026-09-01T00:00:00Z",
                "end": "2026-09-01T01:00:00Z",
            }
        ]
    )
    entry = coverage_row(plan_id=plan["plan_id"])
    client = BigQuery([])
    bucket = SimpleNamespace(labels={}, get_blob=lambda *a, **k: SimpleNamespace(generation="1"))
    monkeypatch.setattr(publisher.cloud, "storage_client", lambda *_: object())
    monkeypatch.setattr(publisher.cloud, "bigquery_client", lambda *_: client)
    monkeypatch.setattr(publisher, "archive_bucket", lambda *_: bucket)
    monkeypatch.setattr(publisher, "read_json", lambda *_: plan)
    monkeypatch.setattr(publisher, "verified_entries", lambda *_: iter([entry]))
    monkeypatch.setattr(publisher, "put_verified", lambda *_args, **_kwargs: None)
    args = SimpleNamespace(
        project="archive-test",
        dataset="telemetry_history",
        bucket="archive-bucket",
        location="us-east4",
        plan_ids=[plan["plan_id"]],
    )
    version = publisher.publish(args)["catalog_version"]
    external_id = f"archive-test.telemetry_history.request_outcomes_files_{version}"
    existing = client.tables[external_id]
    if mismatch == "manifest":
        existing.external_data_configuration = bigquery.ExternalConfig.from_api_repr(
            {
                "sourceFormat": "PARQUET",
                "autodetect": True,
                "fileSetSpecType": "FILE_SET_SPEC_TYPE_NEW_LINE_DELIMITED_MANIFEST",
                "sourceUris": ["gs://archive-bucket/query-manifests/v1/wrong.txt"],
            }
        )
    else:
        existing.schema = [bigquery.SchemaField("source_id", "STRING")]
    aliases_before = [s for s in client.statements if s.startswith("CREATE OR REPLACE VIEW")]
    with pytest.raises(publisher.ArchiveError, match="external table"):
        publisher.publish(args)
    assert [
        s for s in client.statements if s.startswith("CREATE OR REPLACE VIEW")
    ] == aliases_before
