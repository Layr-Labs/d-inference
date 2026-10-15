#!/usr/bin/env python3
"""Copy only verified base objects into a new, immutable R2 serving revision."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import urllib.parse


def publish(manifest, source, helper_source, readback, endpoint):
    parsed = urllib.parse.urlparse(endpoint)
    if parsed.scheme != "https" or not parsed.hostname or not parsed.hostname.endswith(".r2.cloudflarestorage.com"):
        raise ValueError("Expected HTTPS Cloudflare R2 account endpoint")
    if manifest["model_id"] != source["model_id"] or manifest["r2_prefix"] == source["r2_prefix"]:
        raise ValueError("Expected matching identity and a separate new serving prefix")
    expected = [item for item in source["files"] if not item["path"].startswith("mtp/")]
    if manifest["files"] != expected or manifest["file_count"] != 9:
        raise ValueError("Only the nine verified base objects may be copied")
    verified = {item["path"]: item for item in readback["files"]}
    if readback["source_prefix"] != source["r2_prefix"] or set(verified) != {item["path"] for item in manifest["files"]}:
        raise ValueError("Readback must cover exactly the base files from this source")
    for item in manifest["files"]:
        proof = verified[item["path"]]
        if not proof["verified"] or not proof.get("etag") or proof["sha256"] != item["sha256"] or proof["size_bytes"] != item["size_bytes"]:
            raise ValueError("Missing source-bound SHA256/size/ETag receipt")
    bucket = "darkbloom-models"
    with tempfile.TemporaryDirectory(prefix="bonsai9b-base-publish-") as temporary:
        helper_path = Path(temporary) / "immutable_publisher.py"
        helper_path.write_text(helper_source)
        spec = importlib.util.spec_from_file_location("immutable_publisher", helper_path)
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        recorded = helper.read_object(bucket, source["r2_prefix"] + "/manifest.json", endpoint, temporary)
        if recorded is None or helper.identity(json.loads(recorded)) != helper.identity(source):
            raise ValueError("R2 source manifest differs from the verified backup")
        reserved = helper.reserve_revision(manifest, bucket, endpoint, temporary)
        if not reserved:
            print(json.dumps({"status": "already_published", "r2_prefix": manifest["r2_prefix"]}), flush=True)
            return
        def copy_file(item):
            source_key = source["r2_prefix"] + "/" + item["path"]
            destination_key = manifest["r2_prefix"] + "/" + item["path"]
            head = json.loads(helper.aws(["s3api", "head-object", "--bucket", bucket, "--key", source_key], endpoint).stdout)
            if head["ContentLength"] != item["size_bytes"] or head["ETag"] != verified[item["path"]]["etag"]:
                raise ValueError("Source object size changed: " + item["path"])
            copied = json.loads(helper.aws(["s3api", "copy-object", "--bucket", bucket,
                "--key", destination_key, "--copy-source", bucket + "/" + source_key,
                "--copy-source-if-match", verified[item["path"]]["etag"]], endpoint).stdout)
            after = json.loads(helper.aws(["s3api", "head-object", "--bucket", bucket, "--key", destination_key], endpoint).stdout)
            if after["ContentLength"] != item["size_bytes"] or after["ETag"] != copied["CopyObjectResult"]["ETag"]:
                raise ValueError("Destination copy verification failed: " + item["path"])
            print(json.dumps({"copied": item["path"], "bytes": after["ContentLength"]}), flush=True)
            return {"path": item["path"], "size_bytes": after["ContentLength"], "etag": after["ETag"]}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            files = list(pool.map(copy_file, manifest["files"]))
        manifest_path = Path(temporary) / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        helper.aws(["s3api", "put-object", "--bucket", bucket, "--key", manifest["r2_prefix"] + "/manifest.json",
            "--body", str(manifest_path), "--content-type", "application/json", "--if-none-match", "*"], endpoint)
        print(json.dumps({"status": "published", "r2_prefix": manifest["r2_prefix"], "aggregate_sha256": manifest["aggregate_sha256"], "files": files}), flush=True)


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    inputs = json.loads((root / "fixtures/model-publication/bonsai9b-base-2026-10-15.json").read_text())
    if os.environ.get("MODEL_ID") != inputs["manifest"]["model_id"] or os.environ.get("MODEL_VERSION") != inputs["manifest"]["version"]:
        raise ValueError("Bonsai publication only supports the reviewed exact model and revision")
    if not os.environ.get("AWS_ACCESS_KEY_ID") or not os.environ.get("AWS_SECRET_ACCESS_KEY"):
        raise ValueError("Existing R2 publication credentials are required")
    helper_source = (root / "scripts/publish-model-revision.py").read_text()
    publish(inputs["manifest"], inputs["source"], helper_source, inputs["readback"], os.environ["R2_ENDPOINT"])
