#!/usr/bin/env python3
"""Provider install identity, read from provider-swift/identity/provider-identity.json.

That file is the only declaration of the identity values. A release version
that contains a non-production environment's releaseVersionMarker selects that
environment (X.Y.Z-dev.N selects dev, X.Y.Z-staging.N selects staging); any
other version selects prod. The release lane renames the SwiftPM
products (swiftProducts) to the selected cliName and enclaveName when it
packages the app. The flat verifier copies keep the product names because the
coordinator's release registration requires bin/darkbloom.

Run with a version to print the packaged names as KEY=VALUE lines for $GITHUB_ENV,
or with --environment to print the build environment (prod, dev or staging). --source
reads the identity of another checkout.
"""
import argparse
import json
from pathlib import Path

RELATIVE_IDENTITY_FILE = "provider-swift/identity/provider-identity.json"
IDENTITY_FILE = Path(__file__).resolve().parent.parent / RELATIVE_IDENTITY_FILE


def load(path=IDENTITY_FILE):
    document = json.loads(Path(path).read_text())
    environments = set(document.get("environments", {}))
    marker_map = document.get("releaseVersionMarkers", {})
    markers = set(marker_map)
    if (document.get("schema") != 1 or environments != {"prod", "dev", "staging"}
            or markers != environments - {"prod"}):
        raise ValueError(f"{path}: expected schema 1 with prod, dev and staging environments "
                         "and a releaseVersionMarkers entry for each non-production environment")
    # Fail closed: a marker must be a non-empty string that begins with "-", the
    # SemVer pre-release delimiter. An empty marker is a substring of every
    # version and would misroute identity selection; a marker without the
    # leading "-" could match inside a numeric or build-metadata segment.
    for name, marker in marker_map.items():
        if not isinstance(marker, str) or not marker.startswith("-"):
            raise ValueError(f"{path}: releaseVersionMarkers[{name!r}] must be a non-empty "
                             f'string beginning with "-", got {marker!r}')
    return document


DOCUMENT = load()
PRODUCTS = DOCUMENT["swiftProducts"]


def for_source(root):
    """The identity of a source checkout: its own file, or this tooling's when
    the checkout predates the identity file (those sources build only the
    production names, which this tooling's file also gives)."""
    path = Path(root) / RELATIVE_IDENTITY_FILE
    return load(path) if path.is_file() else DOCUMENT


def environment(version, document=DOCUMENT):
    for name, marker in document["releaseVersionMarkers"].items():
        if marker in version:
            return name
    return "prod"


def identity(version, document=DOCUMENT):
    return document["environments"][environment(version, document)]


def github_env(version, document=DOCUMENT):
    names = identity(version, document)
    products = document["swiftProducts"]
    return {"CLI_NAME": names["cliName"], "ENCLAVE_NAME": names["enclaveName"],
            "APP_NAME": names["appBundleName"], "APP_DISPLAY_NAME": names["appDisplayName"],
            "PRODUCT_CLI_NAME": products["cli"], "PRODUCT_ENCLAVE_NAME": products["enclave"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--environment", action="store_true",
                        help="print only the build environment (prod, dev or staging)")
    parser.add_argument("--source", type=Path,
                        help="read the identity of this source checkout (see for_source)")
    parser.add_argument("version")
    arguments = parser.parse_args()
    document = for_source(arguments.source) if arguments.source else DOCUMENT
    if arguments.environment:
        print(environment(arguments.version, document))
        return
    for key, value in github_env(arguments.version, document).items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
