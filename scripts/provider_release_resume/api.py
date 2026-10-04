"""Read-only GitHub API access for retained unsigned release inputs."""
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
        raise ValueError("Resume requires a stable production release tag")
    ref = api.get("git/ref/tags/" + tag)["object"]
    if ref["type"] != "tag":
        raise ValueError("Resume requires a signed annotated tag")
    annotated = api.get("git/tags/" + ref["sha"])
    if annotated.get("verification", {}).get("verified") is not True or annotated["object"]["type"] != "commit":
        raise ValueError("Release tag signature or commit target is invalid")
    return annotated["object"]["sha"]


def verify_tag(api, tag, source):
    if tag_source(api, tag) != source:
        raise ValueError("Release tag no longer identifies the retained build")
