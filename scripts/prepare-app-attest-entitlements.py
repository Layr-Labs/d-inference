#!/usr/bin/env python3
"""Add shadow App Attest grants only when the distribution profile authorizes them.

APNs remains mandatory. A legacy profile keeps the release operational and the
provider reports not_configured on macOS 27. No profile/secret is mutated here.
"""
import argparse
import plistlib
from pathlib import Path

ENVIRONMENT = "com.apple.developer.devicecheck.appattest-environment"
OPT_IN = "com.apple.developer.devicecheck.app-attest-opt-in"


def prepare(base, profile):
    result = dict(base)
    if result.get("com.apple.developer.aps-environment") != "production":
        raise ValueError("APNs production entitlement must remain enabled")
    grants = profile.get("Entitlements", {})
    grant = grants.get(ENVIRONMENT)
    environment_authorized = grant in ("production", "*") if isinstance(grant, str) else (
        isinstance(grant, list) and "production" in grant)
    result.pop(ENVIRONMENT, None)
    result.pop(OPT_IN, None)
    if environment_authorized:
        result[ENVIRONMENT] = "production"
    # Mac Developer ID profiles can grant ONLY Opt-In, without the environment
    # entitlement. Preserve the granted type and request only the mode we use.
    opt_in = grants.get(OPT_IN)
    if opt_in == "CDhash":
        result[OPT_IN] = "CDhash"
    elif (isinstance(opt_in, list) and all(isinstance(mode, str) for mode in opt_in)
          and "CDhash" in opt_in):
        result[OPT_IN] = ["CDhash"]
    return result, OPT_IN in result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify", type=Path, help="Check an extracted signed-entitlements plist")
    args = parser.parse_args()
    with args.base.open("rb") as source:
        base = plistlib.load(source)
    with args.profile.open("rb") as source:
        profile = plistlib.load(source)
    result, authorized = prepare(base, profile)
    if args.verify:
        with args.verify.open("rb") as source:
            signed = plistlib.load(source)
        for key in [ENVIRONMENT, OPT_IN, "com.apple.developer.aps-environment"]:
            if signed.get(key) != result.get(key):
                raise ValueError("Signed entitlement differs from prepared grant: " + key)
    else:
        with args.output.open("wb") as output:
            plistlib.dump(result, output)
    print("App Attest shadow signing: " + ("macOS CDhash opt-in configured" if authorized else "macOS opt-in absent; existing APNs/MDM retained"))


if __name__ == "__main__":
    main()
