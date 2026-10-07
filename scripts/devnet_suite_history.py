#!/usr/bin/env python3
"""Resolve the newest retained DevNet-suite commit from its exact successful run."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
from urllib.parse import urlencode
import zipfile

ARTIFACT = "devnet-suite-tested-commit"
WORKFLOW = ".github/workflows/devnet-suite.yml"
BRANCH = "master"
RETENTION_DAYS = 90
MAX_ELIGIBLE_RUNS = 800
MAX_ARCHIVE_BYTES = 64 * 1024


class GitHub:
    def __init__(self, repository):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("invalid GitHub repository")
        self.repository = repository

    def get(self, path):
        return json.loads(subprocess.check_output(
            ["gh", "api", f"repos/{self.repository}/{path}"], text=True))


    def save(self, path, destination):
        with destination.open("xb") as stream:
            subprocess.run(["gh", "api", f"repos/{self.repository}/{path}"],
                           stdout=stream, check=True)


def positive_id(value):
    if not re.fullmatch(r"[1-9][0-9]{0,19}", str(value)):
        raise ValueError("invalid workflow run or artifact id")
    return int(value)


def trusted_run(run, repository):
    return (run.get("repository", {}).get("full_name") == repository
            and run.get("head_repository", {}).get("full_name") == repository
            and run.get("path") == WORKFLOW
            and run.get("head_branch") == BRANCH
            and re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", "")) is not None
            and run.get("event") in {"schedule", "workflow_run", "workflow_dispatch"}
            and run.get("status") == "completed"
            and run.get("conclusion") == "success")


def read_commit(api, run, artifact):
    artifact_id = positive_id(artifact.get("id"))
    run_id = positive_id(run.get("id"))
    owner = artifact.get("workflow_run", {})
    digest = artifact.get("digest", "")
    if (artifact.get("name") != ARTIFACT or artifact.get("expired") is not False
            or not 0 < artifact.get("size_in_bytes", 0) <= MAX_ARCHIVE_BYTES
            or owner.get("id") != run_id or owner.get("head_branch") != BRANCH
            or owner.get("head_sha") != run.get("head_sha")
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest)):
        raise ValueError("trusted DevNet artifact provenance, expiry, size or digest is invalid")
    with tempfile.TemporaryDirectory(prefix="devnet-history-") as temporary:
        archive = Path(temporary) / "artifact.zip"
        api.save(f"actions/artifacts/{artifact_id}/zip", archive)
        if not 0 < archive.stat().st_size <= MAX_ARCHIVE_BYTES:
            raise ValueError("DevNet artifact transport size is invalid")
        actual = "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != digest:
            raise ValueError("DevNet artifact transport digest differs")
        with zipfile.ZipFile(archive) as zipped:
            files = zipped.infolist()
            if (len(files) != 1 or files[0].filename != "commit.txt" or files[0].is_dir()
                    or stat.S_ISLNK(files[0].external_attr >> 16)
                    or not 0 < files[0].file_size <= 41):
                raise ValueError("unexpected DevNet artifact layout")
            value = zipped.read(files[0])
    if not re.fullmatch(rb"[0-9a-f]{40}\n?", value):
        raise ValueError("invalid retained DevNet commit")
    return value.decode().strip()


def select(api, now=None):
    now = now or datetime.now(timezone.utc)
    cutoff = (now - timedelta(days=RETENTION_DAYS)).date().isoformat()
    query = urlencode({"branch": BRANCH, "status": "success", "created": f">={cutoff}"})
    path = f"actions/workflows/devnet-suite.yml/runs?{query}"
    max_pages = MAX_ELIGIBLE_RUNS // 100
    for page in range(1, max_pages + 2):
        result = api.get(f"{path}&per_page=100&page={page}")
        runs = result.get("workflow_runs")
        if not isinstance(runs, list):
            raise ValueError("malformed workflow-run response")
        if page > max_pages:
            if runs:
                raise ValueError("eligible DevNet runs exceed bounded pagination")
            return None
        for run in runs:
            if not trusted_run(run, api.repository):
                continue
            run_id = positive_id(run.get("id"))
            result = api.get(
                f"actions/runs/{run_id}/artifacts?name={ARTIFACT}&per_page=2"
            )
            artifacts = result.get("artifacts")
            total_count = result.get("total_count")
            if (not isinstance(artifacts, list) or type(total_count) is not int
                    or total_count < 0 or total_count != len(artifacts)):
                raise ValueError("malformed run artifact response")
            matches = [artifact for artifact in artifacts
                       if artifact.get("name") == ARTIFACT and artifact.get("expired") is not True]
            if not matches:
                continue
            if len(matches) != 1 or result.get("total_count") != 1:
                raise ValueError("successful DevNet run has multiple matching artifacts")
            return read_commit(api, run, matches[0])
        if len(runs) < 100:
            return None
    raise ValueError("eligible DevNet runs exceed bounded pagination")


def main():
    try:
        commit = select(GitHub(os.environ["GITHUB_REPOSITORY"]))
    except (KeyError, OSError, subprocess.SubprocessError, ValueError, zipfile.BadZipFile) as error:
        print(f"cannot verify retained DevNet history: {error}", file=os.sys.stderr)
        return 1
    if commit is None:
        print("no retained successful DevNet-suite artifact", file=os.sys.stderr)
        return 3
    print(commit)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
