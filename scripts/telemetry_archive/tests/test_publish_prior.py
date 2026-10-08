"""A published catalog is validated before becoming the next publication's input."""

from copy import deepcopy

import pytest

from telemetry_archive import publish as publisher
from telemetry_archive.backfill_plan import make_plan
from telemetry_archive.model import utc

from .catalog_fixtures import coverage_row
from .test_publish import catalog_publication as catalog_publication


def test_new_plan_preserves_validated_prior_coverage(catalog_publication, monkeypatch):
    args, client = catalog_publication
    first = publisher.publish(args)
    prior_id = f"archive-test.{args.dataset}.catalog_{first['catalog_version']}"
    prior_rows = deepcopy(client.tables[prior_id].rows)
    plan = make_plan(
        [
            {
                "table": "request_outcomes",
                "start": "2026-09-02T00:00:00Z",
                "end": "2026-09-02T01:00:00Z",
            }
        ]
    )
    entry = coverage_row(
        plan_id=plan["plan_id"],
        window_start="2026-09-02T00:00:00Z",
        window_end="2026-09-02T01:00:00Z",
    )
    args.plan_ids = [plan["plan_id"]]
    monkeypatch.setattr(publisher, "read_json", lambda *_: plan)
    monkeypatch.setattr(publisher, "verified_entries", lambda *_: iter([entry]))
    second = publisher.publish(args)
    assert first["catalog_version"] != second["catalog_version"]
    rows = client.tables[f"archive-test.{args.dataset}.catalog_{second['catalog_version']}"].rows
    assert len(rows) == 3
    assert all(row in rows for row in prior_rows)
    assert publisher.publish(args) == second


@pytest.mark.parametrize("mutation", ["newer_count", "dropped", "duplicate", "extra_duplicate"])
@pytest.mark.parametrize("update_metadata", [False, True])
def test_prior_corruption_does_not_switch_aliases(catalog_publication, mutation, update_metadata):
    args, client = catalog_publication
    first = publisher.publish(args)
    prior = client.tables[f"archive-test.{args.dataset}.catalog_{first['catalog_version']}"]
    if mutation == "newer_count":
        prior.rows[0].update(observed_at=utc("2026-09-04T00:00:00Z"), row_count=999)
    elif mutation == "dropped":
        prior.rows.pop()
    elif mutation == "duplicate":
        prior.rows[1] = dict(prior.rows[0])
    else:
        prior.rows.append(dict(prior.rows[0]))
    if update_metadata:
        prior.num_rows = len(prior.rows)
    aliases = dict(client.aliases)
    tables = set(client.tables)
    with pytest.raises(publisher.ArchiveError, match="catalog .* mismatch"):
        publisher.publish(args)
    assert client.aliases == aliases
    assert set(client.tables) == tables


@pytest.mark.parametrize(
    "sql",
    [
        "SELECT * FROM `archive-test.telemetry_history.catalog_{version}` WHERE row_count = 0",
        "SELECT * FROM `archive-test.telemetry_history.catalog_{version}` LIMIT 1",
        "SELECT * FROM `another-project.telemetry_history.catalog_{version}`",
        "SELECT * FROM `archive-test.telemetry_other.catalog_{version}`",
        "SELECT * FROM `archive-test.telemetry_history.arbitrary_view`",
        "SELECT * FROM `archive-test.telemetry_history.catalog_{version}` UNION ALL SELECT 1",
    ],
)
def test_prior_pointer_must_be_exact(catalog_publication, sql):
    args, client = catalog_publication
    first = publisher.publish(args)
    client.aliases[f"archive-test.{args.dataset}.archive_coverage"] = sql.format(
        version=first["catalog_version"]
    )
    aliases = dict(client.aliases)
    client.statements.clear()
    with pytest.raises(publisher.ArchiveError, match="pointer mismatch"):
        publisher.publish(args)
    assert client.aliases == aliases
    assert not client.statements


@pytest.mark.parametrize("mutation", ["description", "digest", "format", "view", "external"])
def test_prior_catalog_identity_is_checked(catalog_publication, mutation):
    args, client = catalog_publication
    first = publisher.publish(args)
    prior = client.tables[f"archive-test.{args.dataset}.catalog_{first['catalog_version']}"]
    if mutation == "description":
        prior.description = "not a verified catalog"
    elif mutation == "digest":
        prior.description = "Verified archive catalog sha256=" + "0" * 64
    elif mutation == "format":
        prior.labels = {"archive_coverage": "unknown"}
    elif mutation == "view":
        prior.table_type = "VIEW"
    else:
        prior.external_data_configuration = object()
    aliases = dict(client.aliases)
    with pytest.raises(publisher.ArchiveError, match="identity mismatch"):
        publisher.publish(args)
    assert client.aliases == aliases


def test_prior_pointer_is_resolved_once(catalog_publication, monkeypatch):
    args, client = catalog_publication
    first = publisher.publish(args)
    coverage_id = f"archive-test.{args.dataset}.archive_coverage"
    get_table = client.get_table
    lookups = []

    def moved_pointer(name):
        table = get_table(name)
        if name == coverage_id:
            lookups.append(name)
            # A concurrent alias change cannot redirect the validation read.
            client.aliases[name] = "SELECT * FROM `untrusted.arbitrary_view`"
        return table

    monkeypatch.setattr(client, "get_table", moved_pointer)
    client.statements.clear()
    assert publisher.publish(args) == first
    assert lookups == [coverage_id]
    assert not any("archive_coverage`" in s for s in client.statements if s.startswith("SELECT"))
    assert all(
        f"catalog_{first['catalog_version']}`" in s
        for s in client.statements
        if s.startswith("SELECT")
    )


@pytest.mark.parametrize("catalog_publication", ["time", "id"], indirect=True)
@pytest.mark.parametrize("null_ids", [False, True])
def test_verified_legacy_catalog_remains_available(catalog_publication, null_ids):
    args, client = catalog_publication
    legacy_row = coverage_row(
        plan_id="old-plan", source_uri="gs://archive-bucket/data/v1/old.parquet"
    )
    if args.dataset.startswith("accounting_"):
        legacy_row.update(
            table_name="usage", window_start=None, window_end=None, id_start=0, id_end=10
        )
    elif null_ids:
        legacy_row.update(id_start=None, id_end=None)
    prior = client.install_legacy([legacy_row], args.dataset)
    first = publisher.publish(args)
    rows = client.tables[f"archive-test.{args.dataset}.catalog_{first['catalog_version']}"].rows
    assert all(row in rows for row in prior.rows)
    assert len(rows) == 3
    assert publisher.publish(args) == first


@pytest.mark.parametrize(
    "mutation", ["newer_count", "dropped", "extra_duplicate", "mixed_encoding"]
)
def test_unverifiable_legacy_catalog_fails_closed(catalog_publication, mutation):
    args, client = catalog_publication
    rows = [coverage_row(source_uri=f"gs://archive-bucket/data/v1/{i}.parquet") for i in range(2)]
    if mutation == "mixed_encoding":
        rows[0].update(id_start=None, id_end=None)
    prior = client.install_legacy(rows)
    if mutation == "newer_count":
        prior.rows[0].update(observed_at=utc("2026-09-04T00:00:00Z"), row_count=999)
    elif mutation == "dropped":
        prior.rows.pop()
    elif mutation == "extra_duplicate":
        prior.rows.append(dict(prior.rows[0]))
    prior.num_rows = len(prior.rows)
    aliases = dict(client.aliases)
    with pytest.raises(publisher.ArchiveError, match="catalog .* mismatch"):
        publisher.publish(args)
    assert client.aliases == aliases
