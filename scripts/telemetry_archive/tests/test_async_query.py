"""No cloud calls: exercise the real BigQuery job/configuration value objects."""

import copy
import json
from datetime import UTC, date, datetime, time
from decimal import Decimal
from types import SimpleNamespace

import pytest
from google.api_core.exceptions import BadRequest, Conflict, ServiceUnavailable
from google.cloud import bigquery

from telemetry_archive import async_query
from telemetry_archive.model import ArchiveError
from telemetry_archive.publish import CATALOG_SCHEMA, FILE_SCHEMA, reader_sql

CATALOG = "a" * 16
PREFIX = "archive-test.accounting_history"


class Rows:
    def __init__(self, rows, schema=(), total_rows=None, token=None):
        self.rows = rows
        self.schema = schema
        self.total_rows = len(rows) if total_rows is None else total_rows
        self.next_page_token = None
        self.token = token

    def __iter__(self):
        return iter(self.rows)

    @property
    def pages(self):
        self.next_page_token = self.token
        yield iter(self.rows)
        pytest.fail("status must read only one result page")


class Client:
    project = "archive-test"

    def __init__(self):
        self.calls = []
        self.jobs = {}
        self.tables = {}
        self.location = "us-east4"
        self.coverage = [{"table_name": "usage"}, {"table_name": "provider_earnings"}]
        self.results = []
        self.schema = []
        self.result_token = None
        self.dry_statistics = {
            "statementType": "SELECT",
            "totalBytesProcessed": "100",
            "referencedTables": [
                {"projectId": "archive-test", "datasetId": "accounting_history", "tableId": t}
                for t in (f"catalog_{CATALOG}", f"usage_files_{CATALOG}")
            ],
        }
        self.tables[f"{PREFIX}.catalog_{CATALOG}"] = bigquery.Table.from_api_repr(
            {
                "tableReference": {
                    "projectId": "archive-test",
                    "datasetId": "accounting_history",
                    "tableId": f"catalog_{CATALOG}",
                },
                "type": "TABLE",
                "description": "Verified archive catalog sha256=" + "a" * 64,
                "labels": {"archive_coverage": "plan_windows_v2"},
                "schema": {"fields": [f.to_api_repr() for f in CATALOG_SCHEMA]},
            }
        )
        for table in ("usage", "provider_earnings"):
            self.tables[f"{PREFIX}.{table}_files_{CATALOG}"] = bigquery.Table.from_api_repr(
                {
                    "tableReference": {
                        "projectId": "archive-test",
                        "datasetId": "accounting_history",
                        "tableId": f"{table}_files_{CATALOG}",
                    },
                    "type": "EXTERNAL",
                    "schema": {
                        "fields": [bigquery.SchemaField(*f).to_api_repr() for f in FILE_SCHEMA]
                    },
                    "externalDataConfiguration": {
                        "sourceFormat": "PARQUET",
                        "fileSetSpecType": "FILE_SET_SPEC_TYPE_NEW_LINE_DELIMITED_MANIFEST",
                        "sourceUris": [f"gs://archive/query-manifests/v1/{CATALOG}/{table}.txt"],
                    },
                }
            )

    def get_dataset(self, name, **kwargs):
        assert kwargs == async_query.RPC
        self.calls.append(("dataset", name))
        return SimpleNamespace(location=self.location)

    def get_table(self, name, **kwargs):
        assert kwargs == async_query.RPC
        self.calls.append(("table", name))
        return self.tables[name]

    def list_rows(self, table, **kwargs):
        self.calls.append(("rows", table, kwargs))
        assert kwargs["timeout"] == 30 and kwargs["retry"] is None
        if table.table_id.startswith("catalog_"):
            assert kwargs["max_results"] == async_query.MAX_COVERAGE_ROWS
            assert [f.name for f in kwargs["selected_fields"]] == ["table_name"]
            return Rows(self.coverage[: kwargs["max_results"]])
        assert table.dataset_id == "_private"
        assert kwargs["page_size"] == kwargs["max_results"] <= 1000
        return Rows(
            self.results[: kwargs["max_results"]], self.schema, len(self.results), self.result_token
        )

    def query(self, sql, job_config, job_id=None, **kwargs):
        assert kwargs == {
            "project": self.project,
            "location": self.location,
            "job_retry": None,
            **async_query.RPC,
        }
        configuration = job_config.to_api_repr()
        configuration["query"]["query"] = sql
        self.calls.append(("query", sql, copy.deepcopy(configuration), job_id))
        if not job_config.dry_run and job_id in self.jobs:
            raise Conflict("SQL and private values must not leak")
        resource = {
            "jobReference": {
                "jobId": job_id or "dry-run",
                "projectId": self.project,
                "location": self.location,
            },
            "configuration": configuration,
            "status": {"state": "DONE" if job_config.dry_run else "RUNNING"},
        }
        if job_config.dry_run:
            resource["statistics"] = {"query": copy.deepcopy(self.dry_statistics)}
        job = bigquery.QueryJob.from_api_repr(resource, self)
        if not job_config.dry_run:
            self.jobs[job_id] = job
        return job

    def get_job(self, job_id, **kwargs):
        assert kwargs == {
            "project": self.project,
            "location": self.location,
            **async_query.RPC,
        }
        self.calls.append(("job", job_id))
        return self.jobs[job_id]

    def cancel_job(self, job_id, **kwargs):
        assert kwargs == {
            "project": self.project,
            "location": self.location,
            **async_query.RPC,
        }
        self.calls.append(("cancel", job_id))
        return self.jobs[job_id]


@pytest.fixture
def setup(tmp_path, monkeypatch):
    path = tmp_path / "query.sql"
    path.write_text("SELECT SUM(source_id) AS total FROM archive_usage")
    args = SimpleNamespace(
        project="archive-test",
        location="us-east4",
        dataset="accounting_history",
        catalog=CATALOG,
        tables=["usage"],
        sql_file=path,
        maximum_bytes_billed=1024**3,
        job_id="archive-query-test-1",
        max_results=100,
        page_token=None,
    )
    client = Client()
    monkeypatch.setattr(async_query.cloud, "bigquery_client", lambda *_: client)
    monkeypatch.setattr(bigquery.QueryJob, "result", lambda *_a, **_k: pytest.fail("waited"))
    return args, client


def complete(args, client, error=None):
    job = client.jobs[args.job_id]
    job._properties["status"] = {"state": "DONE"}
    if error:
        job._properties["status"]["errorResult"] = error
    job._properties["statistics"] = {"query": {"statementType": "SELECT"}}
    job._properties["configuration"]["query"]["destinationTable"] = {
        "projectId": args.project,
        "datasetId": "_private",
        "tableId": "results",
    }
    return job


def test_submit_pins_logical_readers_and_never_waits(setup):
    args, client = setup
    args.tables = ["usage", "provider_earnings"]
    report = async_query.submit(args)
    assert report["job_id"] == args.job_id
    assert report["state"] == "RUNNING" and report["reused"] is False
    assert not report["serving_eligible"] and not report["retention_eligible"]
    assert report["source_completeness"] == "not_certified"
    calls = [c for c in client.calls if c[0] == "query"]
    assert len(calls) == 2
    assert calls[0][2]["dryRun"] is True
    assert calls[1][3] == args.job_id
    for table in args.tables:
        assert (
            f"archive_{table} AS (\n{reader_sql(args.project, args.dataset, table, CATALOG)}"
            in (calls[1][1])
        )
    for call in calls:
        assert call[2]["jobTimeoutMs"] == str(async_query.JOB_TIMEOUT_MS)
        assert call[2]["query"]["maximumBytesBilled"] == str(1024**3)
        assert call[2]["query"]["useLegacySql"] is False
        assert call[2]["query"]["useQueryCache"] is False
        assert "destinationTable" not in call[2]["query"]
    assert "sql" not in report and "SUM" not in json.dumps(report)


@pytest.mark.parametrize("statement", ["SCRIPT", "INSERT", "DELETE", "CREATE_TABLE", "EXPORT_DATA"])
def test_dry_run_rejects_non_select_before_execution(setup, statement):
    args, client = setup
    client.dry_statistics["statementType"] = statement
    with pytest.raises(ArchiveError, match="complete SELECT"):
        async_query.submit(args)
    assert not client.jobs


@pytest.mark.parametrize(
    "table",
    [
        {
            "projectId": "other-project",
            "datasetId": "accounting_history",
            "tableId": f"usage_files_{CATALOG}",
        },
        {
            "projectId": "archive-test",
            "datasetId": "other_dataset",
            "tableId": f"usage_files_{CATALOG}",
        },
        {"projectId": "archive-test", "datasetId": "accounting_history", "tableId": "usage"},
        {
            "projectId": "archive-test",
            "datasetId": "accounting_history",
            "tableId": "usage_files_" + "b" * 16,
        },
        {
            "projectId": "archive-test",
            "datasetId": "accounting_history",
            "tableId": f"provider_earnings_files_{CATALOG}",
        },
        {"tableId": f"usage_files_{CATALOG}"},
    ],
)
def test_dry_run_rejects_unknown_or_out_of_scope_references(setup, table):
    args, client = setup
    client.dry_statistics["referencedTables"].append(table)
    with pytest.raises(ArchiveError, match="outside"):
        async_query.submit(args)
    assert not client.jobs


@pytest.mark.parametrize("missing", ["statementType", "referencedTables", "totalBytesProcessed"])
def test_partial_dry_run_metadata_fails_closed(setup, missing):
    args, client = setup
    del client.dry_statistics[missing]
    with pytest.raises(ArchiveError, match="complete SELECT"):
        async_query.submit(args)
    assert not client.jobs


@pytest.mark.parametrize("value", [[], None, "not-a-list"])
def test_empty_or_malformed_references_fail_closed(setup, value):
    args, client = setup
    client.dry_statistics["referencedTables"] = value
    with pytest.raises(ArchiveError):
        async_query.submit(args)
    assert not client.jobs


def test_routine_references_and_truncated_reference_lists_rejected(setup):
    args, client = setup
    client.dry_statistics["referencedRoutines"] = [{"routineId": "remote_function"}]
    with pytest.raises(ArchiveError):
        async_query.submit(args)
    del client.dry_statistics["referencedRoutines"]
    client.dry_statistics["referencedTables"] *= 25
    with pytest.raises(ArchiveError):
        async_query.submit(args)
    assert not client.jobs


@pytest.mark.parametrize(
    "field,value",
    [
        ("maximum_bytes_billed", 0),
        ("maximum_bytes_billed", 10 * 1024**3 + 1),
        ("job_id", None),
        ("job_id", "automatic"),
        ("job_id", "archive-query-"),
        ("job_id", "archive-query-a/b"),
        ("location", "bad/location"),
        ("tables", []),
        ("tables", ["secrets"]),
        ("tables", ["usage", "request_profiles"]),
        ("dataset", "telemetry_history"),
        ("catalog", "a" * 15),
        ("project", "x`"),
    ],
)
def test_bad_arguments_rejected_before_cloud(setup, field, value):
    args, client = setup
    setattr(args, field, value)
    with pytest.raises(ArchiveError):
        async_query.submit(args)
    assert not client.calls


@pytest.mark.parametrize("source", [b" ", b"\xff", b"x" * (async_query.MAX_SQL_BYTES + 1)])
def test_sql_file_is_bounded_nonempty_utf8(setup, source):
    args, client = setup
    args.sql_file.write_bytes(source)
    with pytest.raises(ArchiveError):
        async_query.submit(args)
    assert not client.calls


def test_byte_limit_checks_estimate_and_accepts_upper_bound(setup):
    args, client = setup
    args.maximum_bytes_billed = 99
    with pytest.raises(ArchiveError, match="byte limit"):
        async_query.submit(args)
    assert not client.jobs
    args.maximum_bytes_billed = async_query.MAX_BYTES_BILLED
    assert async_query.submit(args)["state"] == "RUNNING"


@pytest.mark.parametrize(
    "mismatch",
    [
        "location",
        "description",
        "label",
        "schema",
        "view",
        "coverage",
        "manifest",
        "external_schema",
    ],
)
def test_catalog_and_table_metadata_validated_before_dry_run(setup, mismatch):
    args, client = setup
    catalog = client.tables[f"{PREFIX}.catalog_{CATALOG}"]
    external = client.tables[f"{PREFIX}.usage_files_{CATALOG}"]
    if mismatch == "location":
        client.location = "EU"
    elif mismatch == "description":
        catalog.description = "Verified archive catalog sha256=" + "b" * 64
    elif mismatch == "label":
        catalog.labels = {}
    elif mismatch == "schema":
        catalog.schema = [bigquery.SchemaField("table_name", "STRING")]
    elif mismatch == "view":
        catalog._properties["type"] = "VIEW"
    elif mismatch == "coverage":
        client.coverage = [{"table_name": "provider_earnings"}]
    elif mismatch == "manifest":
        external._properties["externalDataConfiguration"]["sourceUris"] = ["gs://wrong/data/*"]
    else:
        external.schema = []
    with pytest.raises(ArchiveError):
        async_query.submit(args)
    assert not any(c[0] == "query" for c in client.calls)


def test_named_retry_reuses_only_identical_sql_config_and_labels(setup):
    args, client = setup
    async_query.submit(args)
    job = client.jobs[args.job_id]
    assert async_query.submit(args)["reused"] is True
    assert client.jobs[args.job_id] is job and len(client.jobs) == 1
    # Server-assigned destination and dispositions do not change request identity.
    complete(args, client)
    assert async_query.submit(args)["reused"] is True
    args.sql_file.write_text("SELECT COUNT(*) FROM archive_usage")
    with pytest.raises(ArchiveError, match="different query"):
        async_query.submit(args)
    assert client.jobs[args.job_id] is job


@pytest.mark.parametrize("change", ["bytes", "tables", "label", "query", "timeout", "destination"])
def test_named_retry_rejects_configuration_changes(setup, change):
    args, client = setup
    async_query.submit(args)
    job = client.jobs[args.job_id]
    config = job._properties["configuration"]
    if change == "bytes":
        args.maximum_bytes_billed += 1
    elif change == "tables":
        args.tables.append("provider_earnings")
    elif change == "label":
        config["labels"]["extra"] = "different"
    elif change == "query":
        config["query"]["query"] = "SELECT 42"
    elif change == "timeout":
        config["jobTimeoutMs"] = "600000"
    else:
        config["query"]["destinationTable"] = {
            "projectId": args.project,
            "datasetId": "public",
            "tableId": "results",
        }
    with pytest.raises(ArchiveError):
        async_query.submit(args)
    assert len(client.jobs) == 1


def test_running_status_is_one_snapshot_without_results_or_waiting(setup):
    args, client = setup
    async_query.submit(args)
    client.calls.clear()
    assert async_query.status(args)["state"] == "RUNNING"
    assert client.calls == [("job", args.job_id)]


def test_completed_results_are_exact_recursive_typed_and_single_page(setup):
    args, client = setup
    async_query.submit(args)
    complete(args, client)
    client.results = [
        {
            "sum": Decimal("123456789012345678901234567890.123456789"),
            "nested": [
                bigquery.Row((Decimal(2**63 + 1),), {"large": 0}),
                {
                    "date": date(2026, 10, 4),
                    "timestamp": datetime(2026, 10, 4, tzinfo=UTC),
                    "datetime": datetime(2026, 10, 4),
                    "time": time(12, 30),
                    "bytes": b"\x00\xff",
                    "nan": float("nan"),
                    "null": None,
                    "flag": True,
                    "int": 2**63 - 1,
                },
            ],
        }
    ] * 1100
    client.schema = [bigquery.SchemaField("sum", "BIGNUMERIC")]
    args.max_results = 1000
    args.page_token = "previous-token"
    client.result_token = "next-token"
    report = async_query.status(args)
    assert len(report["rows"]) == 1000
    row = report["rows"][0]
    assert row["sum"] == "123456789012345678901234567890.123456789"
    assert row["nested"][0]["large"] == str(2**63 + 1)
    assert row["nested"][1] == {
        "date": "2026-10-04",
        "timestamp": "2026-10-04T00:00:00+00:00",
        "datetime": "2026-10-04T00:00:00",
        "time": "12:30:00",
        "bytes": "AP8=",
        "nan": "nan",
        "null": None,
        "flag": True,
        "int": 2**63 - 1,
    }
    assert report["next_page_token"] == "next-token"
    assert report["schema"][0]["type"] == "BIGNUMERIC"
    assert report["total_rows"] == 1100
    assert client.calls[-1][2]["page_token"] == "previous-token"
    json.dumps(report, allow_nan=False)


@pytest.mark.parametrize("limit", [0, 1001, -1])
def test_polling_result_limit_rejected_before_cloud(setup, limit):
    args, client = setup
    args.max_results = limit
    with pytest.raises(ArchiveError, match="max-results"):
        async_query.status(args)
    assert not client.calls


def test_completed_failure_returns_only_controlled_summary(setup):
    args, client = setup
    async_query.submit(args)
    complete(args, client, {"reason": "invalidQuery", "message": "secret SQL and credentials"})
    client.calls.clear()
    report = async_query.status(args)
    assert report["error"] == "query_failed"
    assert "secret" not in json.dumps(report)
    assert client.calls == [("job", args.job_id)]


@pytest.mark.parametrize("operation", [async_query.status, async_query.cancel])
@pytest.mark.parametrize("change", ["tool", "hash", "project", "location", "id", "type"])
def test_status_and_cancel_reject_unowned_jobs(setup, operation, change):
    args, client = setup
    async_query.submit(args)
    job = client.jobs[args.job_id]
    if change in ("tool", "hash"):
        label = "archive_tool" if change == "tool" else "archive_request"
        job._properties["configuration"]["labels"][label] = "other"
    elif change == "type":
        client.jobs[args.job_id] = SimpleNamespace(labels={}, job_type="load")
    else:
        key = {"project": "projectId", "location": "location", "id": "jobId"}[change]
        job._properties["jobReference"][key] = "other"
    client.calls.clear()
    with pytest.raises(ArchiveError):
        operation(args)
    assert client.calls == [("job", args.job_id)]


def test_cancel_only_owned_running_job_and_does_not_claim_stopped(setup):
    args, client = setup
    async_query.submit(args)
    client.calls.clear()
    report = async_query.cancel(args)
    assert report["cancel_requested"] and report["state"] == "RUNNING"
    assert client.calls == [("job", args.job_id), ("cancel", args.job_id)]
    complete(args, client)
    client.calls.clear()
    assert async_query.cancel(args)["cancel_requested"] is False
    assert client.calls == [("job", args.job_id)]


@pytest.mark.parametrize("operation", [async_query.submit, async_query.status, async_query.cancel])
def test_cloud_errors_cannot_expose_sql_or_credentials(setup, monkeypatch, operation):
    args, client = setup

    def fail(*_a, **_k):
        raise BadRequest("private SQL and credentials")

    monkeypatch.setattr(
        client, "get_dataset" if operation == async_query.submit else "get_job", fail
    )
    with pytest.raises(ArchiveError) as caught:
        operation(args)
    assert "private SQL" not in str(caught.value)
    assert "credentials" not in str(caught.value)


def test_lost_submission_response_retries_same_job_without_reexecution(setup, monkeypatch):
    args, client = setup
    query = client.query

    def lose_response(sql, job_config, **kwargs):
        job = query(sql, job_config, **kwargs)
        if not job_config.dry_run:
            raise ServiceUnavailable("connection lost after accepting SQL")
        return job

    monkeypatch.setattr(client, "query", lose_response)
    with pytest.raises(ArchiveError):
        async_query.submit(args)
    assert len(client.jobs) == 1
    monkeypatch.setattr(client, "query", query)
    assert async_query.submit(args)["reused"] is True
    assert len(client.jobs) == 1


def test_failed_named_job_is_not_reexecuted_on_retry(setup):
    args, client = setup
    async_query.submit(args)
    original = complete(args, client, {"reason": "stopped", "message": "private data"})
    report = async_query.submit(args)
    assert report["reused"] and report["state"] == "DONE"
    assert client.jobs[args.job_id] is original
    assert len(client.jobs) == 1


def test_select_comments_and_write_words_are_not_a_regex_security_filter(setup):
    args, _ = setup
    args.sql_file.write_text(
        "-- SELECT-only operator report\n"
        "SELECT 'DROP TABLE, EXPORT DATA, DELETE' AS words FROM archive_usage LIMIT 1;"
    )
    assert async_query.submit(args)["state"] == "RUNNING"


def test_coverage_read_does_not_scan_unbounded_catalog(setup):
    args, client = setup
    client.coverage = [{"table_name": "provider_earnings"}] * async_query.MAX_COVERAGE_ROWS
    client.coverage.append({"table_name": "usage"})
    with pytest.raises(ArchiveError, match="bounded metadata read"):
        async_query.submit(args)
    assert not client.jobs


def test_empty_completed_result_page(setup):
    args, client = setup
    async_query.submit(args)
    complete(args, client)
    report = async_query.status(args)
    assert report["rows"] == []
    assert report["next_page_token"] is None and report["total_rows"] == 0


@pytest.mark.parametrize("page_token", ["x" * 16_385, 42])
def test_invalid_page_token_rejected_before_cloud(setup, page_token):
    args, client = setup
    args.page_token = page_token
    with pytest.raises(ArchiveError, match="page token"):
        async_query.status(args)
    assert not client.calls


def test_corrupt_owned_job_byte_metadata_has_controlled_error(setup):
    args, client = setup
    async_query.submit(args)
    config = client.jobs[args.job_id]._properties["configuration"]
    config["query"]["maximumBytesBilled"] = "private data"
    with pytest.raises(ArchiveError, match="byte limit metadata") as caught:
        async_query.status(args)
    assert "private data" not in str(caught.value)
