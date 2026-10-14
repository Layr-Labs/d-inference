#!/usr/bin/env python3
"""Provider install identity, read from provider-swift/identity/provider-identity.json.

That file is the only declaration of the identity values. A release version
that contains its releaseVersionMarker (X.Y.Z-dev.N) selects the dev
identity; any other version selects prod. The release lane renames the SwiftPM
products (swiftProducts) to the selected cliName and enclaveName when it
packages the app. The flat verifier copies keep the product names because the
coordinator's release registration requires bin/darkbloom.

Run with a version to print the packaged names as KEY=VALUE lines for $GITHUB_ENV,
or with --environment and a version to print the build environment (prod or dev).
"""
import json
from pathlib import Path
import sys

IDENTITY_FILE = Path(__file__).resolve().parent.parent / "provider-swift/identity/provider-identity.json"


def load(path=IDENTITY_FILE):
    document = json.loads(Path(path).read_text())
    if document.get("schema") != 1 or set(document.get("environments", {})) != {"prod", "dev"}:
        raise ValueError(f"{path}: expected schema 1 with prod and dev environments")
    return document


DOCUMENT = load()
PRODUCTS = DOCUMENT["swiftProducts"]


def environment(version):
    return "dev" if DOCUMENT["releaseVersionMarker"] in version else "prod"


def identity(version):
    return DOCUMENT["environments"][environment(version)]


def github_env(version):
    names = identity(version)
    return {"CLI_NAME": names["cliName"], "ENCLAVE_NAME": names["enclaveName"],
            "APP_NAME": names["appBundleName"], "APP_DISPLAY_NAME": names["appDisplayName"],
            "PRODUCT_CLI_NAME": PRODUCTS["cli"], "PRODUCT_ENCLAVE_NAME": PRODUCTS["enclave"]}


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--environment":
        print(environment(sys.argv[2]))
        return
    if len(sys.argv) != 2:
        raise SystemExit("usage: provider_release_identity.py [--environment] <version>")
    for key, value in github_env(sys.argv[1]).items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
