"""Publication separates exact source-window coverage from unique scan files."""

from datetime import timedelta, timezone
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
                rows=[],
            ),
        )

    def load_table_from_json(self, rows, name, job_config):
        assert job_config.write_disposition == "WRITE_EMPTY"
        self.loaded = rows
        self.tables[name].num_rows = len(rows)
        self.tables[name].rows = [
            {
                field.name: (
                    utc(row[field.name])
                    if field.field_type == "TIMESTAMP" and row.get(field.name) is not None
                    else row.get(field.name)
                )
                for field in job_config.schema
            }
            for row in rows
        ]
        return Job()

    def query(self, sql, job_config=None):
        self.statements.append(sql)
        if sql.startswith("SELECT *") and ".catalog_" in sql:
            assert job_config.maximum_bytes_billed == 64 * 1024**2
            assert job_config.use_query_cache is False
            name = sql.split("`")[1]
            limit = int(sql.rsplit(" LIMIT ", 1)[1])
            return Job(self.tables[name].rows[:limit])
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


@pytest.fixture
def catalog_publication(monkeypatch, request):
    plan = make_plan(
        [
            {
                "table": "request_outcomes",
                "start": "2026-09-01T00:00:00Z",
                "end": "2026-09-01T02:00:00Z",
            }
        ]
    )
    entries = [
        coverage_row(plan_id=plan["plan_id"]),
        coverage_row(
            plan_id=plan["plan_id"],
            window_start="2026-09-01T01:00:00Z",
            window_end="2026-09-01T02:00:00Z",
            observed_at="2026-09-03T00:00:00.123456Z",
        ),
    ]
    scope = "telemetry"
    if getattr(request, "param", "time") == "id":
        scope = "accounting"
        plan = make_plan([{"table": "usage", "id_start": 0, "id_end": 20}])
        for index, entry in enumerate(entries):
            entry.update(
                table_name="usage",
                plan_id=plan["plan_id"],
                window_start=None,
                window_end=None,
                id_start=index * 10,
                id_end=(index + 1) * 10,
            )
    client = BigQuery([])
    bucket = SimpleNamespace(
        labels={"archive-scope": scope},
        get_blob=lambda *a, **k: SimpleNamespace(generation="1"),
    )
    monkeypatch.setattr(publisher.cloud, "storage_client", lambda *_: object())
    monkeypatch.setattr(publisher.cloud, "bigquery_client", lambda *_: client)
    monkeypatch.setattr(publisher, "archive_bucket", lambda *_: bucket)
    monkeypatch.setattr(publisher, "read_json", lambda *_: plan)
    monkeypatch.setattr(publisher, "verified_entries", lambda *_: iter(entries))
    monkeypatch.setattr(publisher, "put_verified", lambda *_args, **_kwargs: None)
    args = SimpleNamespace(
        project="archive-test",
        dataset=f"{scope}_history",
        bucket="archive-bucket",
        location="us-east4",
        plan_ids=[plan["plan_id"]],
    )
    return args, client


@pytest.mark.parametrize("mismatch", ["type", "mode", "missing", "extra", "order"])
def test_publisher_rejects_reused_catalog_schema(catalog_publication, mismatch):
    args, client = catalog_publication
    version = publisher.publish(args)["catalog_version"]
    catalog = client.tables[f"archive-test.telemetry_history.catalog_{version}"]
    catalog.schema = list(catalog.schema)
    if mismatch == "type":
        catalog.schema[0] = bigquery.SchemaField("table_name", "INTEGER", "REQUIRED")
    elif mismatch == "mode":
        catalog.schema[0] = bigquery.SchemaField("table_name", "STRING", "NULLABLE")
    elif mismatch == "missing":
        catalog.schema.pop()
    elif mismatch == "extra":
        catalog.schema.append(bigquery.SchemaField("unexpected", "STRING"))
    else:
        catalog.schema.reverse()
    client.statements.clear()
    with pytest.raises(publisher.ArchiveError, match="catalog schema mismatch"):
        publisher.publish(args)
    assert not any(sql.startswith("CREATE OR REPLACE VIEW") for sql in client.statements)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("table_name", "route_outcomes"),
        ("source_uri", "gs://archive-bucket/data/v1/other.parquet"),
        ("generation", "2"),
        ("observed_at", utc("2026-09-04T00:00:00Z")),
        ("window_start", None),
        ("window_end", utc("2026-09-01T00:30:00Z")),
        ("row_count", 1),
        ("parquet_bytes", 43),
        ("plan_id", "another-plan"),
        ("id_start", 0),
        ("id_end", 10),
    ],
)
def test_publisher_rejects_same_count_catalog_changes(catalog_publication, field, value):
    args, client = catalog_publication
    version = publisher.publish(args)["catalog_version"]
    catalog = client.tables[f"archive-test.telemetry_history.catalog_{version}"]
    catalog.rows[0][field] = value
    client.statements.clear()
    with pytest.raises(publisher.ArchiveError, match="catalog"):
        publisher.publish(args)
    assert not any(sql.startswith("CREATE OR REPLACE VIEW") for sql in client.statements)


@pytest.mark.parametrize("mismatch", ["missing", "duplicate", "extra"])
def test_publisher_rejects_partial_or_duplicate_catalog(catalog_publication, mismatch):
    args, client = catalog_publication
    version = publisher.publish(args)["catalog_version"]
    catalog = client.tables[f"archive-test.telemetry_history.catalog_{version}"]
    if mismatch == "missing":
        catalog.rows.pop()
    elif mismatch == "duplicate":
        catalog.rows[1] = dict(catalog.rows[0])
    else:
        catalog.rows.append(dict(catalog.rows[0]))
    # Leave metadata unchanged to exercise the actual row-count/digest checks.
    client.statements.clear()
    with pytest.raises(publisher.ArchiveError, match="catalog .* mismatch"):
        publisher.publish(args)
    assert not any(sql.startswith("CREATE OR REPLACE VIEW") for sql in client.statements)


@pytest.mark.parametrize("catalog_publication", ["time", "id"], indirect=True)
def test_publisher_retries_unchanged_catalog_with_normalized_rows(catalog_publication, monkeypatch):
    args, client = catalog_publication
    first = publisher.publish(args)
    catalog = client.tables[f"archive-test.{args.dataset}.catalog_{first['catalog_version']}"]
    catalog.rows.reverse()
    for row in catalog.rows:
        if args.dataset.startswith("telemetry_"):
            assert row["id_start"] is None and row["id_end"] is None
        else:
            assert row["window_start"] is None and row["window_end"] is None
        for field in ("observed_at", "window_start", "window_end"):
            if row[field] is not None:
                row[field] = row[field].astimezone(timezone(timedelta(hours=3)))

    def unexpected_load(*_args, **_kwargs):
        pytest.fail("unchanged catalog must not be reloaded")

    monkeypatch.setattr(client, "load_table_from_json", unexpected_load)
    assert publisher.publish(args) == first


@pytest.mark.parametrize("mismatch", ["partial", "content"])
def test_publisher_verifies_newly_loaded_catalog(catalog_publication, monkeypatch, mismatch):
    args, client = catalog_publication
    load = client.load_table_from_json

    def altered_load(rows, name, job_config):
        job = load(rows, name, job_config)
        if mismatch == "partial":
            client.tables[name].rows.pop()
        else:
            client.tables[name].rows[0]["parquet_bytes"] += 1
        return job

    monkeypatch.setattr(client, "load_table_from_json", altered_load)
    with pytest.raises(publisher.ArchiveError, match="catalog .* mismatch"):
        publisher.publish(args)
    assert not any(sql.startswith("CREATE OR REPLACE VIEW") for sql in client.statements)
