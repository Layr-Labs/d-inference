#!/usr/bin/env python3
"""Run the real installer end to end with stub system and network commands.

A dev release must install as darkbloom-dev in ~/.darkbloom-dev and a
production release as darkbloom in ~/.darkbloom. Neither install may touch the
other's files.
"""

import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parent / "install.sh"
BUNDLE_URL = "https://bundles.invalid/provider.tar.gz"
DEV_COORD = "https://api.dev.darkbloom.dev"
PROD_COORD = "https://api.darkbloom.dev"
PROD_RC_BLOCK = '\n# Darkbloom\nexport PATH="$HOME/.darkbloom/bin:$PATH"\n'
DEV_RC_BLOCK = '\n# Darkbloom Dev\nexport PATH="$HOME/.darkbloom-dev/bin:$PATH"\n'

# The provider executable stub carries the paged-runtime capability string
# that the installer looks for, and passes the packaged runtime smoke.
PROVIDER_STUB = b"#!/bin/sh\n# engine_v2_kv_backend\nexit 0\n"

STUBS = {
    "uname": '[ "${1:-}" = -m ] && echo arm64 || echo Darwin\n',
    "sysctl": 'case "$*" in *memsize*) echo 68719476736 ;; *) echo "Apple M5" ;; esac\n',
    "sw_vers": "echo 27.0\n",
    # Model the real codesign verdict: a correctly (Apple-anchored) signed app
    # satisfies any requirement, but an ad-hoc signature cannot satisfy a
    # requirement that demands `anchor apple generic`. With STUB_CODESIGN_ADHOC=1
    # a --verify ... -R=<req> call fails when <req> carries the Apple anchor.
    "codesign": 'echo "codesign $*" >> "$STUB_TRACE"\n'
                'if [ "${STUB_CODESIGN_ADHOC:-0}" = 1 ]; then\n'
                '    for arg in "$@"; do\n'
                '        case "$arg" in -R=*"anchor apple generic"*) exit 1 ;; esac\n'
                '    done\n'
                'fi\n',
    "profiles": 'echo "profiles $*" >> "$STUB_TRACE"\n',
    # Never write outside the test home: refuse /usr/local/bin like a
    # non-admin account does.
    "ln": 'echo "ln $*" >> "$STUB_TRACE"\n'
          'for arg in "$@"; do case "$arg" in /usr/local/*) exit 1 ;; esac; done\n'
          'exec "$REAL_LN" "$@"\n',
    "curl": 'out="" url=""\n'
            'while [ "$#" -gt 0 ]; do\n'
            '    case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; *) url=$1; shift ;; esac\n'
            'done\n'
            'echo "curl $url" >> "$STUB_TRACE"\n'
            'case "$url" in\n'
            '    */v1/releases/latest) cat "$STUB_RELEASE_JSON" ;;\n'
            '    "$STUB_BUNDLE_URL") cp "$STUB_BUNDLE" "$out" ;;\n'
            '    *) exit 22 ;;\n'
            'esac\n',
}


def bundle(app_name, cli_name, enclave_name):
    """Return (tarball bytes, binary hash, metallib hash) for a fake release."""
    metallib = b"metallib\n"
    app = f"{app_name}/Contents"
    files = {
        f"{app}/MacOS/{cli_name}": (PROVIDER_STUB, 0o755),
        f"{app}/MacOS/{enclave_name}": (PROVIDER_STUB, 0o755),
        f"{app}/MacOS/mlx.metallib": (metallib, 0o644),
        f"{app}/Resources/darkbloom-runtime-capabilities/paged-kernel-v1": (b"1\n", 0o644),
        f"{app}/Resources/mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal": (b"kernel\n", 0o644),
        "bin/darkbloom": (PROVIDER_STUB, 0o755),
        "bin/darkbloom-enclave": (PROVIDER_STUB, 0o755),
        "bin/mlx.metallib": (metallib, 0o644),
    }
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
        for name, (content, mode) in files.items():
            info = tarfile.TarInfo(f"./{name}")
            info.size = len(content)
            info.mode = mode
            archive.addfile(info, io.BytesIO(content))
    return (buffer.getvalue(), hashlib.sha256(PROVIDER_STUB).hexdigest(),
            hashlib.sha256(metallib).hexdigest())


def write_dev_install(home):
    """Create an installed dev provider, its configuration and its rc block."""
    app_bin = home / ".darkbloom-dev/Darkbloom Dev.app/Contents/MacOS"
    app_bin.mkdir(parents=True)
    (app_bin / "darkbloom-dev").write_bytes(b"dev provider\n")
    (home / ".darkbloom-dev/bin").mkdir()
    os.symlink("../Darkbloom Dev.app/Contents/MacOS/darkbloom-dev", home / ".darkbloom-dev/bin/darkbloom-dev")
    (home / ".config/darkbloom-dev").mkdir(parents=True)
    (home / ".config/darkbloom-dev/provider.toml").write_text(
        '[coordinator]\nurl = "wss://api.dev.darkbloom.dev/ws/provider"\n')
    (home / ".zshrc").write_text(DEV_RC_BLOCK)


def tree(root):
    """Map every path under root to its file bytes or symlink target."""
    found = {}
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            found[relative] = "-> " + os.readlink(path)
        elif path.is_file():
            found[relative] = path.read_bytes()
    return found


class InstallerIdentityTests(unittest.TestCase):
    def install(self, version, coord_url, app_name, cli_name, enclave_name, prepare=None,
                adhoc=False):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        home, stubs, tmp = root / "home", root / "stubs", root / "tmp"
        for path in (home, stubs, tmp):
            path.mkdir()
        for name, body in STUBS.items():
            stub = stubs / name
            stub.write_text("#!/bin/bash\n" + body)
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        archive, binary_hash, metallib_hash = bundle(app_name, cli_name, enclave_name)
        (root / "bundle.tar.gz").write_bytes(archive)
        (root / "release.json").write_text(json.dumps({
            "version": version, "url": BUNDLE_URL,
            "bundle_hash": hashlib.sha256(archive).hexdigest(),
            "binary_hash": binary_hash, "metallib_hash": metallib_hash,
            "backend": "mlx-swift",
        }, separators=(",", ":")))
        if prepare:
            prepare(home)
        result = subprocess.run(
            ["bash", str(INSTALLER)],
            env={"PATH": f"{stubs}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
                 "TMPDIR": str(tmp), "COORD_URL": coord_url,
                 "REAL_LN": "/bin/ln", "STUB_TRACE": str(root / "trace"),
                 "STUB_RELEASE_JSON": str(root / "release.json"),
                 "STUB_BUNDLE_URL": BUNDLE_URL, "STUB_BUNDLE": str(root / "bundle.tar.gz"),
                 "STUB_CODESIGN_ADHOC": "1" if adhoc else "0"},
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
        trace = (root / "trace").read_text() if (root / "trace").exists() else ""
        self.assertEqual(list(tmp.iterdir()), [], result.stdout + result.stderr)
        return result, home, trace

    def assert_installed(self, home, install_dir, app_name, cli_name, enclave_name):
        bin_dir = home / install_dir / "bin"
        self.assertEqual(sorted(path.name for path in bin_dir.iterdir()),
                         sorted([cli_name, enclave_name, "mlx.metallib"]))
        self.assertEqual(os.readlink(bin_dir / cli_name), f"../{app_name}/Contents/MacOS/{cli_name}")
        self.assertEqual(os.readlink(bin_dir / enclave_name),
                         f"../{app_name}/Contents/MacOS/{enclave_name}")
        self.assertEqual(os.readlink(bin_dir / "mlx.metallib"), f"../{app_name}/Contents/MacOS/mlx.metallib")
        self.assertTrue((bin_dir / cli_name).resolve().is_file())
        self.assertEqual(sorted(path.name for path in (home / install_dir).iterdir()), sorted([app_name, "bin"]))

    def test_dev_release_installs_as_darkbloom_dev_beside_production(self):
        production = {}

        def existing_production_install(home):
            app_bin = home / ".darkbloom/Darkbloom.app/Contents/MacOS"
            app_bin.mkdir(parents=True)
            (app_bin / "darkbloom").write_bytes(b"production provider\n")
            (home / ".darkbloom/bin").mkdir()
            os.symlink("../Darkbloom.app/Contents/MacOS/darkbloom", home / ".darkbloom/bin/darkbloom")
            (home / ".config/darkbloom").mkdir(parents=True)
            (home / ".config/darkbloom/provider.toml").write_text("[provider]\nname = \"mac\"\n")
            (home / ".zshrc").write_text("export EDITOR=vi\n" + PROD_RC_BLOCK)
            production.update(darkbloom=tree(home / ".darkbloom"), config=tree(home / ".config/darkbloom"))

        result, home, trace = self.install(
            "0.9.20-dev.152", DEV_COORD, "Darkbloom Dev.app", "darkbloom-dev", "darkbloom-enclave-dev",
            existing_production_install)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_installed(home, ".darkbloom-dev", "Darkbloom Dev.app", "darkbloom-dev",
                              "darkbloom-enclave-dev")
        self.assertEqual((home / ".config/darkbloom-dev/provider.toml").read_text(),
                         '[coordinator]\nurl = "wss://api.dev.darkbloom.dev/ws/provider"\n')
        self.assertEqual(tree(home / ".darkbloom"), production["darkbloom"])
        self.assertEqual(tree(home / ".config/darkbloom"), production["config"])
        self.assertEqual((home / ".zshrc").read_text(), "export EDITOR=vi\n" + PROD_RC_BLOCK + DEV_RC_BLOCK)

        self.assertIn(f"Provider: Darkbloom Dev (darkbloom-dev, installs in {home}/.darkbloom-dev)",
                      result.stdout)
        self.assertIn(f"Installed: Darkbloom Dev v0.9.20-dev.152 in {home}/.darkbloom-dev", result.stdout)
        self.assertIn("Command:   darkbloom-dev\n", result.stdout)
        self.assertIn("darkbloom-dev login", result.stdout)
        self.assertIn(f"ln -sf {home}/.darkbloom-dev/bin/darkbloom-dev /usr/local/bin/darkbloom-dev", trace)
        self.assertNotIn("profiles", trace)
        for text in (result.stdout, result.stderr, trace):
            self.assertNotIn("/.darkbloom/", text)
            self.assertNotIn("/.config/darkbloom/", text)
            self.assertNotIn("Darkbloom.app", text)
            for line in text.splitlines():
                for word in line.replace("/", " ").split():
                    self.assertNotIn(word.strip("`'\"()"), {"darkbloom", "darkbloom-enclave"}, line)

    def test_production_release_installs_as_darkbloom_and_keeps_dev(self):
        dev = {}

        def existing_dev_install(home):
            write_dev_install(home)
            dev.update(darkbloom=tree(home / ".darkbloom-dev"), config=tree(home / ".config/darkbloom-dev"))

        result, home, trace = self.install(
            "0.9.20", PROD_COORD, "Darkbloom.app", "darkbloom", "darkbloom-enclave", existing_dev_install)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_installed(home, ".darkbloom", "Darkbloom.app", "darkbloom", "darkbloom-enclave")
        self.assertFalse((home / ".config/darkbloom").exists())
        self.assertEqual(tree(home / ".darkbloom-dev"), dev["darkbloom"])
        self.assertEqual(tree(home / ".config/darkbloom-dev"), dev["config"])
        self.assertEqual((home / ".zshrc").read_text(), DEV_RC_BLOCK + PROD_RC_BLOCK)
        self.assertIn(f"Provider: Darkbloom (darkbloom, installs in {home}/.darkbloom)", result.stdout)
        self.assertIn(f"Installed: Darkbloom v0.9.20 in {home}/.darkbloom", result.stdout)
        self.assertIn("Command:   darkbloom\n", result.stdout)
        for text in (result.stdout, result.stderr, trace):
            self.assertNotIn("darkbloom-dev", text)
            self.assertNotIn("Darkbloom Dev", text)

    def test_dev_release_without_the_dev_executable_is_refused(self):
        before = {}

        def existing_dev_install(home):
            write_dev_install(home)
            before.update(tree(home))

        result, home, _ = self.install(
            "0.9.20-dev.152", DEV_COORD, "Darkbloom Dev.app", "darkbloom", "darkbloom-enclave-dev",
            existing_dev_install)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Release bundle Darkbloom Dev.app has no Contents/MacOS/darkbloom-dev, "
                      "which a Darkbloom Dev release must contain.", result.stderr)
        self.assertIn("Existing installation was left unchanged.", result.stdout)
        self.assertEqual(tree(home), before)
        self.assertEqual(sorted(path.name for path in (home / ".darkbloom-dev").iterdir()),
                         ["Darkbloom Dev.app", "bin"])
        self.assertFalse((home / ".darkbloom").exists())

    def test_dev_release_with_the_production_app_name_is_refused(self):
        result, home, _ = self.install(
            "0.9.20-dev.152", DEV_COORD, "Darkbloom.app", "darkbloom-dev", "darkbloom-enclave-dev")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Release bundle has no Darkbloom Dev.app; flat-only bundles are no longer installable.",
                      result.stderr)
        self.assertFalse((home / ".darkbloom").exists())

    def test_prerelease_dev_release_installs_with_an_adhoc_signature(self):
        # Option B: a -dev. build is self-signed. The installer relaxes only the
        # Apple-anchor/team-OU clause, so an ad-hoc signature installs.
        result, home, trace = self.install(
            "0.9.20-dev.branch.7", DEV_COORD, "Darkbloom Dev.app", "darkbloom-dev",
            "darkbloom-enclave-dev", adhoc=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_installed(home, ".darkbloom-dev", "Darkbloom Dev.app", "darkbloom-dev",
                              "darkbloom-enclave-dev")
        # The relaxed requirement keeps the bundle identifier pinned and drops
        # the Apple anchor and team OU.
        self.assertIn('-R=identifier "io.darkbloom.provider"', trace)
        self.assertNotIn("anchor apple generic", trace)

    def test_prerelease_staging_release_installs_with_an_adhoc_signature(self):
        # The same relaxation covers the -staging. marker, and a -staging. build
        # installs as its own darkbloom-staging identity beside production.
        result, home, trace = self.install(
            "0.9.20-staging.3", "https://api.staging.darkbloom.dev", "Darkbloom Staging.app",
            "darkbloom-staging", "darkbloom-enclave-staging", adhoc=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_installed(home, ".darkbloom-staging", "Darkbloom Staging.app",
                              "darkbloom-staging", "darkbloom-enclave-staging")
        self.assertIn('-R=identifier "io.darkbloom.provider"', trace)
        self.assertNotIn("anchor apple generic", trace)

    def test_production_release_with_an_adhoc_signature_is_refused(self):
        # Prod verification is unchanged: an ad-hoc signature cannot satisfy the
        # full Apple-team requirement, so the install is refused.
        result, home, trace = self.install(
            "0.9.21", PROD_COORD, "Darkbloom.app", "darkbloom", "darkbloom-enclave", adhoc=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Staged Darkbloom.app does not satisfy the pinned signature requirement.",
                      result.stderr)
        self.assertIn("Existing installation was left unchanged.", result.stdout)
        self.assertIn('-R=anchor apple generic and identifier "io.darkbloom.provider" '
                      'and certificate leaf[subject.OU] = "SLDQ2GJ6TL"', trace)
        # No app is committed; only the empty install skeleton remains.
        self.assertFalse((home / ".darkbloom/Darkbloom.app").exists())
        self.assertEqual(list((home / ".darkbloom/bin").iterdir()), [])

    def test_marker_only_matches_the_semver_prerelease_component(self):
        # Review hardening: the pre-release match is anchored to the SemVer
        # pre-release component, not an unanchored substring. A marker that
        # appears only in +build metadata (1.2.3+x-dev.y), or that is not the
        # exact dev./staging. pre-release token (devX has no dot, DEV. is the
        # wrong case), is NOT a pre-release. The installer keeps the full
        # Apple-team requirement and refuses the ad-hoc signature.
        for version in ("1.2.3+x-dev.y", "1.2.3-devX", "1.2.3-DEV.1"):
            with self.subTest(version=version):
                result, home, trace = self.install(
                    version, PROD_COORD, "Darkbloom.app", "darkbloom",
                    "darkbloom-enclave", adhoc=True)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                # The full Apple-team requirement was used, not the relaxed one.
                self.assertIn('-R=anchor apple generic and identifier "io.darkbloom.provider" '
                              'and certificate leaf[subject.OU] = "SLDQ2GJ6TL"', trace)
                self.assertNotIn('-R=identifier', trace)
                self.assertFalse((home / ".darkbloom/Darkbloom.app").exists())


if __name__ == "__main__":
    unittest.main()
