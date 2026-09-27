import hashlib
import json
from types import SimpleNamespace

import pytest

from telemetry_archive import snapshot_sync
from telemetry_archive.model import ArchiveError

from .fake_storage import Client


def setup(monkeypatch, tmp_path, *, complete=True):
    client = Client()
    client.bucket.labels = {"archive-scope": "accounting"}
    monkeypatch.setattr(snapshot_sync.cloud, "storage_client", lambda *_: client)
    raw = json.dumps(
        {"schema_version": 1, "source_complete": complete, "generation": "g1"}
    ).encode()
    digest = hashlib.sha256(raw).hexdigest()
    name = f"analytics/v1/snapshots/{digest}.json"
    pointer = json.dumps({"name": name, "sha256": digest, "generation": "2"}).encode()
    client.bucket.objects[name] = (raw, {}, 2)
    client.bucket.objects["analytics/v1/current.json"] = (pointer, {}, 3)
    output = tmp_path / "snapshot.json"
    output.write_bytes(b"previous")
    args = SimpleNamespace(
        project="archive-test", bucket="archive-test", location="us-east4", output=output
    )
    return args, client, name, raw


def test_sync_pins_generation_checks_hash_and_stages_atomically(monkeypatch, tmp_path):
    args, _, _, raw = setup(monkeypatch, tmp_path)
    assert snapshot_sync.sync_snapshot(args)["generation"] == "g1"
    assert args.output.read_bytes() == raw
    assert args.output.stat().st_mode & 0o777 == 0o600
    assert not list(tmp_path.glob(".analytics-*"))


@pytest.mark.parametrize("failure", ["generation", "checksum", "scope", "partial", "path"])
def test_sync_failure_preserves_prior_file(monkeypatch, tmp_path, failure):
    args, client, name, raw = setup(monkeypatch, tmp_path, complete=failure != "partial")
    if failure == "generation":
        client.bucket.objects[name] = (raw, {}, 4)
    elif failure == "checksum":
        client.bucket.objects[name] = (raw + b" ", {}, 2)
    elif failure == "scope":
        client.bucket.labels = {}
    elif failure == "path":
        args.output = args.output.relative_to(tmp_path)
    with pytest.raises(ArchiveError):
        snapshot_sync.sync_snapshot(args)
    assert (tmp_path / "snapshot.json").read_bytes() == b"previous"
