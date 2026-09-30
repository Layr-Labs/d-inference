"""Bind resume selection to one trusted tag run, attempt and immutable artifact."""
import base64
import re

from .api import tag_source

WORKFLOW = ".github/workflows/release-swift.yml"
BUILD_JOB = "Build optimized SDK 27 provider"
QUALIFY_JOB = "Qualify provider with SDK 27"
SIGN_JOB = "Sign, notarize and retain exact artifact"
MAX_ARCHIVE_BYTES = 2 << 30


def positive_integer(value):
    if not re.fullmatch(r"[1-9][0-9]{0,19}", str(value)):
        raise ValueError("Invalid workflow run or attempt")
    return int(value)


def select(api, run_id, attempt):
    run_id, attempt = positive_integer(run_id), positive_integer(attempt)
    run = api.get(f"actions/runs/{run_id}")
    if (run.get("repository", {}).get("full_name") != api.repository
            or run.get("head_repository", {}).get("full_name") != api.repository
            or run.get("path") != WORKFLOW or run.get("event") != "push"
            or run.get("status") != "completed"
            or run.get("conclusion") not in {"failure", "cancelled"}
            or attempt > run.get("run_attempt", 0)):
        raise ValueError("Resume requires a completed failed production tag run in this repository")
    source, tag = run["head_sha"], run["head_branch"]
    if not re.fullmatch(r"[0-9a-f]{40}", source) or tag_source(api, tag) != source:
        raise ValueError("Retained run and current release tag differ")
    commit = api.get("commits/" + source)
    if commit.get("commit", {}).get("verification", {}).get("verified") is not True:
        raise ValueError("Retained source commit is not verified")
    version = tag[1:]
    for path, pattern in [
        ("provider-swift/Sources/ProviderCore/ProviderCore.swift", r'public static let version = "([^"]+)"'),
        ("coordinator/api/server.go", r'var LatestProviderVersion = "([^"]+)"'),
    ]:
        file = api.get(f"contents/{path}?ref={source}")
        values = re.findall(pattern, base64.b64decode(file["content"]).decode())
        if values != [version]:
            raise ValueError("Retained source version differs from release tag")
    jobs = api.pages(f"actions/runs/{run_id}/attempts/{attempt}/jobs", "jobs")
    for name in [BUILD_JOB, QUALIFY_JOB]:
        matches = [job for job in jobs if job.get("name") == name]
        if len(matches) != 1 or matches[0].get("status") != "completed" or matches[0].get("conclusion") != "success":
            raise ValueError("Retained attempt lacks successful build and SDK qualification")
    signing = [job for job in jobs if job.get("name") == SIGN_JOB]
    if len(signing) != 1 or signing[0].get("conclusion") not in {"failure", "cancelled", "skipped"}:
        raise ValueError("Resume must start from an unsuccessful signing job")
    artifacts = api.pages(f"actions/runs/{run_id}/artifacts", "artifacts")
    if any(row.get("name", "").startswith("provider-publication-" + source + "-") for row in artifacts):
        raise ValueError("A signed artifact exists; resume publication instead of signing again")
    name = f"unsigned-provider-{source}-{attempt}"
    matches = [row for row in artifacts if row.get("name") == name]
    if len(matches) != 1:
        raise ValueError("Expected one immutable unsigned artifact for the selected attempt")
    artifact = matches[0]
    owner = artifact.get("workflow_run", {})
    if (artifact.get("expired") is not False
            or not 0 < artifact.get("size_in_bytes", 0) <= MAX_ARCHIVE_BYTES
            or owner.get("id") != run_id or owner.get("head_sha") != source
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", ""))):
        raise ValueError("Unsigned artifact provenance, digest, expiry or size is invalid")
    return {"source_sha": source, "release_tag": tag, "version": version,
            "build_run_id": str(run_id), "build_run_attempt": str(attempt),
            "unsigned_artifact": name, "unsigned_artifact_id": str(positive_integer(artifact["id"])),
            "unsigned_artifact_digest": artifact["digest"], "build_sdk_version": "27.0"}
