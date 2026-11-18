#!/usr/bin/env python3
"""Sign the unsigned desktop app with codesign alone, then verify it.

release-desktop.yml builds the app in a job that holds no key, and signs it
here in a job that runs nothing from npm: this script and codesign are the only
code that runs while the signing keychain exists.

The app is signed inside out: every Mach-O file and every nested .app and
.framework under Contents, deepest first, then the app itself, each with the
hardened runtime, a secure timestamp and the entitlements of
desktop-app/resources/entitlements.mac.plist. That is the set of options
electron-builder signs a local build with, so both paths produce the same code
signature (scripts/test-sign-desktop-app.py).

usage: sign-desktop-app.py APP --identity SHA1 --keychain PATH --entitlements PLIST
"""
import argparse
from pathlib import Path
import os
import subprocess
import sys

# Thin and universal Mach-O files, in either byte order.
MACHO_MAGICS = {bytes.fromhex(magic) for magic in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
NESTED_BUNDLES = (".app", ".framework")


def is_macho(path):
    with path.open("rb") as stream:
        return stream.read(4) in MACHO_MAGICS


def signing_order(app):
    """Everything to sign, in order: nested code deepest first, the app last."""
    contents = app / "Contents"
    if app.suffix != ".app" or app.is_symlink() or not contents.is_dir():
        raise ValueError(f"Not an app bundle: {app}")
    nested = []
    # Symbolic links are never followed: a framework's Versions/Current and its
    # top-level links name files that are signed once, at their real path.
    for directory, names, files in os.walk(contents):
        root = Path(directory)
        names[:] = sorted(name for name in names if not (root / name).is_symlink())
        nested.extend(root / name for name in names if name.endswith(NESTED_BUNDLES))
        nested.extend(root / name for name in sorted(files)
                      if not (root / name).is_symlink() and is_macho(root / name))
    nested.sort(key=lambda path: (-len(path.parts), str(path)))
    return nested + [app]


def sign(app, identity, keychain, entitlements):
    if not entitlements.is_file() or entitlements.is_symlink():
        raise ValueError(f"Missing entitlements: {entitlements}")
    for path in signing_order(app):
        subprocess.run(["codesign", "--sign", identity, "--force", "--keychain", str(keychain),
                        "--timestamp", "--options", "runtime", "--entitlements", str(entitlements),
                        str(path)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app", type=Path)
    parser.add_argument("--identity", required=True, help="SHA-1 fingerprint of the signing certificate")
    parser.add_argument("--keychain", type=Path, required=True)
    parser.add_argument("--entitlements", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        sign(arguments.app, arguments.identity, arguments.keychain, arguments.entitlements)
    except ValueError as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
