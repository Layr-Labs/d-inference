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


PROVIDER_TAG = r"v[0-9]+\.[0-9]+\.[0-9]+"
DESKTOP_TAG = r"desktop-v[0-9]+\.[0-9]+\.[0-9]+"


def tag_source(api, tag, pattern=PROVIDER_TAG):
    """The commit of a signed annotated release tag whose name matches `pattern`."""
    if not re.fullmatch(pattern, tag):
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


# The branches whose ancestry can carry a release source. Only master is
# reviewed; a dev source signs a dev release only (verify_workflow_source).
SOURCE_BRANCHES = {"master": "reviewed master", "dev": "dev"}


def verify_source(api, source, branch="master"):
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("Invalid release source commit")
    commit = api.get("commits/" + source)
    if commit.get("commit", {}).get("verification", {}).get("verified") is not True:
        raise ValueError("Release source commit is not verified")
    head = api.get("git/ref/heads/" + branch)["object"]["sha"]
    comparison = api.get(f"compare/{source}...{head}")
    if (comparison.get("status") not in {"ahead", "identical"}
            or comparison.get("merge_base_commit", {}).get("sha") != source):
        raise ValueError(f"Release source is not on {SOURCE_BRANCHES[branch]} ancestry")
    return head


def verify_validation_source(api, env, source):
    """Signing validation signs a commit on reviewed master, with master's tooling."""
    if env.get("GITHUB_EVENT_NAME") != "workflow_dispatch" or env.get("GITHUB_REF") != "refs/heads/master":
        raise ValueError("Signing validation must be dispatched on master")
    verify_source(api, env["GITHUB_SHA"])
    verify_source(api, source)
    return source


def verify_desktop_source(api, env):
    """The source of a desktop app run, and whether the run publishes.

    A release is a signed annotated desktop-vX.Y.Z tag whose commit is verified
    and on reviewed master. A dry run is a dispatch on the current master
    commit; it signs and verifies and publishes nothing.
    """
    source = env["GITHUB_SHA"]
    event = env.get("GITHUB_EVENT_NAME")
    ref = env.get("GITHUB_REF")
    master = verify_source(api, source)
    if event == "push" and env.get("GITHUB_REF_TYPE") == "tag":
        tag = env["GITHUB_REF_NAME"]
        if ref != "refs/tags/" + tag:
            raise ValueError("Release tag ref mismatch")
        if tag_source(api, tag, DESKTOP_TAG) != source:
            raise ValueError("Desktop release tag does not identify the workflow commit")
        return source, True
    if event == "workflow_dispatch":
        if ref != "refs/heads/master" or source != master:
            raise ValueError("A desktop dry run must be dispatched on the current reviewed master commit")
        return source, False
    raise ValueError("A desktop release requires a signed desktop-v tag on master or a dispatch on master")


def verify_workflow_source(api, env):
    source = env["GITHUB_SHA"]
    event = env.get("GITHUB_EVENT_NAME")
    ref_type = env.get("GITHUB_REF_TYPE")
    ref = env.get("GITHUB_REF")
    if event in ("push", "workflow_dispatch") and ref_type == "branch" and ref == "refs/heads/dev":
        # A dev push or dev-branch dispatch signs and publishes a dev release
        # only, never staging or prod. The commit must be GitHub-verified and on
        # dev ancestry; a dispatched dev release must be the current dev head.
        if env.get("RELEASE_ENVIRONMENT") != "dev":
            raise ValueError("Dev branch push releases require environment dev")
        dev_head = verify_source(api, source, "dev")
        if event == "workflow_dispatch" and source != dev_head:
            raise ValueError("Dispatched dev branch releases must be the current dev commit")
        return source
    master = verify_source(api, source)
    if event == "push" and ref_type == "tag":
        tag = env["GITHUB_REF_NAME"]
        if ref != "refs/tags/" + tag:
            raise ValueError("Release tag ref mismatch")
        verify_tag(api, tag, source)
    elif event == "push" and ref_type == "branch":
        # A master push publishes staging only. verify_source proved the commit is
        # verified and on master ancestry; master may already have moved on.
        if ref != "refs/heads/master":
            raise ValueError("Branch push releases require master or dev")
    elif event == "workflow_dispatch":
        if ref != "refs/heads/master" or source != master:
            raise ValueError("Manual release tooling must be the current reviewed master commit")
    else:
        raise ValueError("Release requires a trusted tag push, a master or dev push, "
                         "or a manual dispatch on master")
    return source
