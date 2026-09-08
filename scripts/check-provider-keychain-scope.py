#!/usr/bin/env python3
"""Read-only validation of the signed provider's Keychain access scope."""

import pathlib
import plistlib
import re
import subprocess
import sys


APP_ID = "SLDQ2GJ6TL.io.darkbloom.provider"
FORBIDDEN = (
    "get-task-allow",
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.allow-dyld-environment-variables",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-executable-page-protection",
    "com.apple.security.cs.allow-jit",
)


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(args, check=True, capture_output=True)


def entitlements(path: pathlib.Path) -> dict:
    result = run("codesign", "-d", "--entitlements", "-", "--xml", str(path))
    return plistlib.loads(result.stdout)


def validate(app: pathlib.Path) -> None:
    main = app / "Contents/MacOS/darkbloom"
    run("codesign", "--verify", "--deep", "--strict", str(app))
    requirement = (
        'anchor apple generic and identifier "io.darkbloom.provider" '
        'and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
    )
    run("codesign", "--verify", "--strict", "-R=" + requirement, str(main))
    current = entitlements(main)
    if current.get("com.apple.application-identifier") != APP_ID:
        raise ValueError("main application identifier mismatch")
    if APP_ID not in current.get("keychain-access-groups", []):
        raise ValueError("main Keychain access group is missing")
    for name in FORBIDDEN:
        if name in current and current[name] is not False:
            raise ValueError("main runtime exception is not permitted: " + name)
    details = run("codesign", "-dv", str(main)).stderr.decode()
    flags = re.search(r"flags=0x([0-9a-fA-F]+)", details)
    if not flags or not int(flags.group(1), 16) & 0x10000:
        raise ValueError("main hardened runtime is missing")
    for relative in ("Contents/MacOS/darkbloom-enclave", "Contents/Helpers/darkbloom-fan-helper"):
        helper = app / relative
        if not helper.is_file():
            raise ValueError("required helper missing: " + relative)
        run("codesign", "--verify", "--strict", str(helper))
        # An empty entitlement result is valid for a helper; malformed output is not.
        output = run("codesign", "-d", "--entitlements", "-", "--xml", str(helper)).stdout
        helper_entitlements = plistlib.loads(output) if output.strip() else {}
        for name in ("keychain-access-groups", "com.apple.application-identifier", "application-identifier"):
            if name in helper_entitlements:
                raise ValueError("helper has application Keychain scope: " + relative)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("usage: check-provider-keychain-scope.py APP")
        validate(pathlib.Path(sys.argv[1]))
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print("provider-keychain-scope: failed: " + str(error), file=sys.stderr)
        sys.exit(1)
    print("provider-keychain-scope: ok")
