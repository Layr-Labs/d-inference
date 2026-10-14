#!/usr/bin/env python3
"""Packaged app names of a provider release, selected by its version.

A dev release (version X.Y.Z-dev.N) is packaged as Darkbloom Dev.app with the
executables darkbloom-dev and darkbloom-enclave-dev, so that it installs beside
production and nobody can confuse the two. These names must agree with
BuildEnvironment in provider-swift/Sources/ProviderBuildEnvironment and with
select_provider_identity in scripts/install.sh.

These names do not change: the SwiftPM products (darkbloom, darkbloom-enclave),
which packaging renames; the flat verifier copies bin/darkbloom and
bin/darkbloom-enclave and the bundle file name, which the coordinator's release
registration requires; the bundle identifier and the signing identity.

Run with a version to print the names as KEY=VALUE lines for $GITHUB_ENV.
"""
import sys

PRODUCTS = {"cli": "darkbloom", "enclave": "darkbloom-enclave"}


def identity(version):
    if "-dev." in version:
        return {"cli": "darkbloom-dev", "enclave": "darkbloom-enclave-dev",
                "app": "Darkbloom Dev.app", "display_name": "Darkbloom Dev"}
    return {"cli": "darkbloom", "enclave": "darkbloom-enclave",
            "app": "Darkbloom.app", "display_name": "Darkbloom"}


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: provider_release_identity.py <version>")
    names = identity(sys.argv[1])
    for key, variable in [("cli", "CLI_NAME"), ("enclave", "ENCLAVE_NAME"), ("app", "APP_NAME"),
                          ("display_name", "APP_DISPLAY_NAME")]:
        print(f"{variable}={names[key]}")


if __name__ == "__main__":
    main()
