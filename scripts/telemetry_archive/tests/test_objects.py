import hashlib
import json

import pytest

from telemetry_archive.artifact import json_bytes
from telemetry_archive.model import ArchiveError
from telemetry_archive.objects import check_generations, load_remote, upload

from .fake_storage import Client


def test_retry_reuses_exact_verified_objects(artifact):
    directory, _ = artifact
    client = Client()
    first = upload(directory, client, "archive-test", "us-east4")
    second = upload(directory, client, "archive-test", "us-east4")
    assert first == second
    assert client.bucket.sequence == 3
    readback, _ = load_remote(client, first["receipt_uri"], "us-east4")
    assert readback["snapshot"]["stats"]["rows"] == 3


@pytest.mark.parametrize("failure", ["data/", "manifests/", "receipts/"])
def test_partial_upload_has_no_commit_receipt_and_can_resume(artifact, failure):
    directory, _ = artifact
    client = Client()
    client.bucket.fail_prefix = failure
    with pytest.raises(RuntimeError):
        upload(directory, client, "archive-test", "us-east4")
    assert not any(name.startswith("receipts/") for name in client.bucket.objects)
    client.bucket.fail_prefix = None
    result = upload(directory, client, "archive-test", "us-east4")
    load_remote(client, result["receipt_uri"], "us-east4")
    assert client.bucket.sequence == 3


@pytest.mark.parametrize("unsafe", ["class", "region", "public", "lifecycle", "acl"])
def test_bucket_preflight_before_writes(artifact, unsafe):
    client = Client()
    if unsafe == "class":
        client.bucket.storage_class = "ARCHIVE"
    elif unsafe == "region":
        client.bucket.location = "US"
    elif unsafe == "public":
        client.bucket.iam_configuration.public_access_prevention = "inherited"
    elif unsafe == "acl":
        client.bucket.iam_configuration.uniform_bucket_level_access_enabled = False
    else:
        client.bucket.lifecycle_rules = [{"action": {"type": "Delete"}, "condition": {"age": 30}}]
    with pytest.raises(ArchiveError):
        upload(artifact[0], client, "archive-test", "us-east4")
    assert not client.bucket.objects


def test_primary_capture_cannot_be_uploaded(artifact):
    directory, receipt = artifact
    receipt["source"]["in_recovery"] = False
    del receipt["artifact_id"]
    receipt["artifact_id"] = hashlib.sha256(json_bytes(receipt)).hexdigest()
    (directory / "receipt.json").write_bytes(json_bytes(receipt))
    client = Client()
    with pytest.raises(ArchiveError, match="physical read replica"):
        upload(directory, client, "archive-test", "us-east4")
    assert not client.bucket.objects


@pytest.mark.parametrize("kind", ["bytes", "generation", "manifest"])
def test_remote_tamper_or_replacement_rejected(artifact, kind):
    client = Client()
    result = upload(artifact[0], client, "archive-test", "us-east4")
    entry = result["manifest" if kind == "manifest" else "data"]
    data, metadata, generation = client.bucket.objects[entry["name"]]
    if kind == "generation":
        generation += 100
    else:
        data = data[:-1] + bytes([data[-1] ^ 1])
    client.bucket.objects[entry["name"]] = data, metadata, generation
    with pytest.raises(ArchiveError):
        load_remote(client, result["receipt_uri"], "us-east4")


def test_receipt_cannot_redirect_to_arbitrary_object(artifact):
    client = Client()
    result = upload(artifact[0], client, "archive-test", "us-east4")
    name = result["receipt_uri"].split("archive-test/", 1)[1]
    data, metadata, generation = client.bucket.objects[name]
    forged = json.loads(data)
    forged["data"]["name"] = "unrelated/object"
    data = json_bytes(forged)
    metadata["sha256"] = hashlib.sha256(data).hexdigest()
    client.bucket.objects[name] = data, metadata, generation
    with pytest.raises(ArchiveError, match="unexpected object"):
        load_remote(client, result["receipt_uri"], "us-east4")


def test_replacement_during_bigquery_cannot_pass(artifact):
    client = Client()
    result = upload(artifact[0], client, "archive-test", "us-east4")
    check_generations(client.bucket, result)
    name = result["data"]["name"]
    data, metadata, generation = client.bucket.objects[name]
    client.bucket.objects[name] = data, metadata, generation + 1
    with pytest.raises(ArchiveError, match="during BigQuery"):
        check_generations(client.bucket, result)
