"""Explicit recovery of a qualified unsigned production build."""
import argparse
import json
import os
from pathlib import Path

from .api import GitHub, verify_desktop_source, verify_tag, verify_validation_source, verify_workflow_source
from .artifact import download
from .identity import select


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["verify-source", "verify-validation-source", "verify-desktop-source",
                                              "resolve", "download"])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--source", help="verify-validation-source: the commit a signing validation builds")
    args = parser.parse_args()
    env = os.environ
    api = GitHub(env["GITHUB_REPOSITORY"])
    if args.operation == "verify-validation-source":
        if args.source is None:
            parser.error("verify-validation-source requires --source")
        verify_validation_source(api, env, args.source)
        return
    if args.operation == "verify-desktop-source":
        source, publish = verify_desktop_source(api, env)
        with open(env["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"source_sha={source}\npublish={str(publish).lower()}\n")
        return
    if args.operation == "verify-source":
        source = verify_workflow_source(api, env)
        with open(env["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"source_sha={source}\n")
        return
    if args.operation == "resolve":
        if (env.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
                or env.get("GITHUB_REF") != "refs/heads/master"
                or env.get("RELEASE_ENVIRONMENT") != "prod"
                or env.get("RELEASE_VALIDATION_ONLY", "false") != "false"
                or env.get("RELEASE_VERSION_OVERRIDE")):
            raise ValueError("Unsigned recovery requires an explicit prod dispatch on master with no version override")
        if api.get("git/ref/heads/master")["object"]["sha"] != env["GITHUB_SHA"]:
            raise ValueError("Recovery tooling must be the current reviewed master commit")
    selection = select(api, env["RELEASE_RESUME_RUN_ID"], env.get("RELEASE_RESUME_RUN_ATTEMPT", "1"))
    if args.operation == "resolve":
        values = dict(selection, environment="prod", publish="true", resume="true")
        with open(env["GITHUB_OUTPUT"], "a") as stream:
            for name, value in values.items():
                stream.write(f"{name}={value}\n")
        print(json.dumps(selection, indent=2))
    else:
        if args.output is None:
            parser.error("download requires --output")
        for key, name in [("source_sha", "RELEASE_SOURCE_SHA"), ("unsigned_artifact_id", "RELEASE_UNSIGNED_ARTIFACT_ID"),
                          ("unsigned_artifact_digest", "RELEASE_UNSIGNED_ARTIFACT_DIGEST")]:
            if selection[key] != env[name]:
                raise ValueError("Retained selection changed after resolution: " + key)
        download(api, selection, args.output)
        verify_tag(api, selection["release_tag"], selection["source_sha"])
