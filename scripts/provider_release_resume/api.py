"""Read-only GitHub checks for reviewed release sources and retained inputs."""
import json
import re
import subprocess


class GitHub:
    def __init__(self, repository):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("Invalid repository")
        self.repository = repository

    def get(self, path):
        return json.loads(subprocess.check_output(
            ["gh", "api", f"repos/{self.repository}/{path}"], text=True))

    def pages(self, path, key):
        rows = []
        for page in range(1, 21):
            result = self.get(f"{path}?per_page=100&page={page}")[key]
            rows.extend(result)
            if len(result) < 100:
                return rows
        raise ValueError("GitHub result exceeds bounded pagination")

    def save(self, path, destination):
        with destination.open("xb") as stream:
            subprocess.run(["gh", "api", f"repos/{self.repository}/{path}"],
                           stdout=stream, check=True)


def tag_source(api, tag):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError("Release requires a stable production release tag")
    ref = api.get("git/ref/tags/" + tag)["object"]
    if ref["type"] != "tag":
        raise ValueError("Release requires a signed annotated tag")
    annotated = api.get("git/tags/" + ref["sha"])
    if annotated.get("verification", {}).get("verified") is not True or annotated["object"]["type"] != "commit":
        raise ValueError("Release tag signature or commit target is invalid")
    return annotated["object"]["sha"]


def verify_tag(api, tag, source):
    if tag_source(api, tag) != source:
        raise ValueError("Release tag no longer identifies the retained build")


def verify_source(api, source):
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("Invalid release source commit")
    commit = api.get("commits/" + source)
    if commit.get("commit", {}).get("verification", {}).get("verified") is not True:
        raise ValueError("Release source commit is not verified")
    master = api.get("git/ref/heads/master")["object"]["sha"]
    comparison = api.get(f"compare/{source}...{master}")
    if (comparison.get("status") not in {"ahead", "identical"}
            or comparison.get("merge_base_commit", {}).get("sha") != source):
        raise ValueError("Release source is not on reviewed master ancestry")
    return master


def verify_workflow_source(api, env):
    source = env["GITHUB_SHA"]
    master = verify_source(api, source)
    if env.get("GITHUB_EVENT_NAME") == "push" and env.get("GITHUB_REF_TYPE") == "tag":
        tag = env["GITHUB_REF_NAME"]
        if env.get("GITHUB_REF") != "refs/tags/" + tag:
            raise ValueError("Release tag ref mismatch")
        verify_tag(api, tag, source)
    elif env.get("GITHUB_EVENT_NAME") == "push" and env.get("GITHUB_REF_TYPE") == "branch":
        # A master push publishes dev only. verify_source proved the commit is
        # verified and on master ancestry; master may already have moved on.
        if env.get("GITHUB_REF") != "refs/heads/master":
            raise ValueError("Branch push releases require master")
    elif env.get("GITHUB_EVENT_NAME") == "workflow_dispatch":
        if env.get("GITHUB_REF") != "refs/heads/master" or source != master:
            raise ValueError("Manual release tooling must be the current reviewed master commit")
    else:
        raise ValueError("Release requires a trusted tag push, a master push or a manual dispatch on master")
    return source
