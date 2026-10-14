#!/usr/bin/env python3
"""Check that every copy of the provider identity matches provider-identity.json."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import unittest

import provider_release_identity as release_identity

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "generate_provider_identity", ROOT / "scripts/generate-provider-identity.py")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)

DOCUMENT = json.loads(release_identity.IDENTITY_FILE.read_text())
PROD, DEV = (DOCUMENT["environments"][name] for name in ("prod", "dev"))
MARKER = DOCUMENT["releaseVersionMarker"]
PROD_VERSION, DEV_VERSION = "0.9.20", "0.9.20" + MARKER + "7"
HOME = "/Users/op"


class ProviderIdentityTests(unittest.TestCase):
    def test_generated_swift_and_docs_tables_match_the_json(self):
        for path, content in GENERATOR.outputs(DOCUMENT).items():
            with self.subTest(path=str(path.relative_to(ROOT))):
                self.assertEqual(path.read_text(), content,
                                 "run scripts/generate-provider-identity.py")

    def test_json_fields_are_the_swift_identity_api(self):
        generated = GENERATOR.SWIFT.read_text()
        self.assertEqual(re.findall(r"public var (\w+):", generated), list(GENERATOR.FIELDS))
        for environment in (PROD, DEV):
            self.assertEqual(set(environment), set(GENERATOR.FIELDS))
        handwritten = (GENERATOR.SWIFT.parent / "BuildEnvironment.swift").read_text()
        self.assertNotRegex(handwritten, r"case \.(prod|dev): return")

    def test_dev_values_are_declared_only_in_the_json(self):
        values = {value for field, value in DEV.items()
                  if isinstance(value, str) and value != PROD[field]}
        allowed = {GENERATOR.SWIFT}
        sources = [*ROOT.glob("provider-swift/Sources/**/*.swift"), *ROOT.glob("scripts/*.py"),
                   *ROOT.glob(".github/**/*.yml")]
        for path in sources:
            if path in allowed or path.name.startswith("test-") or path.name.startswith("test_"):
                continue
            text = path.read_text()
            for value in values:
                with self.subTest(path=str(path.relative_to(ROOT)), value=value):
                    self.assertNotIn(f'"{value}"', text)
                    self.assertNotIn(f"'{value}'", text)

    def test_release_module_reads_the_json(self):
        self.assertEqual(release_identity.identity(PROD_VERSION), PROD)
        self.assertEqual(release_identity.identity(DEV_VERSION), DEV)
        for version, names in [(PROD_VERSION, PROD), (DEV_VERSION, DEV)]:
            output = subprocess.run(
                ["python3", str(ROOT / "scripts/provider_release_identity.py"), version],
                capture_output=True, text=True, check=True).stdout
            self.assertEqual(dict(line.split("=", 1) for line in output.splitlines()), {
                "CLI_NAME": names["cliName"], "ENCLAVE_NAME": names["enclaveName"],
                "APP_NAME": names["appBundleName"], "APP_DISPLAY_NAME": names["appDisplayName"],
                "PRODUCT_CLI_NAME": DOCUMENT["swiftProducts"]["cli"],
                "PRODUCT_ENCLAVE_NAME": DOCUMENT["swiftProducts"]["enclave"]})

    def test_installer_copy_matches_the_json(self):
        # install.sh runs as `curl | bash`, so it keeps literals; this is its guard.
        source = (ROOT / "scripts/install.sh").read_text()
        start = source.index("select_provider_identity() {")
        function = source[start:source.index("\n}\n", start) + 3]
        self.assertIn(f"*{MARKER}*)", function)
        self.assertIn(f'PRODUCTION_COORD_URL="{PROD["coordinatorHTTPURL"]}"', source)
        for version, names in [(PROD_VERSION, PROD), (DEV_VERSION, DEV)]:
            with self.subTest(version=version):
                script = function + f'select_provider_identity "{version}"\n' + \
                    'printf "%s\\n" "$CLI_NAME" "$ENCLAVE_NAME" "$APP_NAME" "$PROVIDER_LABEL" ' \
                    '"$INSTALL_DIR" "$PROVIDER_CONFIG"\n'
                output = subprocess.run(["bash", "-euc", script], env={"HOME": HOME},
                                        capture_output=True, text=True, check=True).stdout
                self.assertEqual(output.splitlines(), [
                    names["cliName"], names["enclaveName"], names["appBundleName"],
                    names["appDisplayName"], f'{HOME}/{names["installDirectoryName"]}',
                    f'{HOME}/{names["configDirectoryName"]}/provider.toml'])

    def test_release_scripts_use_the_version_marker(self):
        resolve = (ROOT / "scripts/resolve-provider-release.sh").read_text()
        self.assertIn(f'[[ "$GITHUB_REF_NAME" == *{MARKER}* ]]', resolve)
        self.assertIn(f'release_version="${{release_version}}{MARKER}${{GITHUB_RUN_NUMBER}}"', resolve)
        check = (ROOT / "scripts/check-release-version.sh").read_text()
        self.assertIn('"$PROVIDER_VERSION"' + MARKER.replace(".", "\\.") + "[1-9]", check)

    def test_flat_verifier_names_are_the_swift_products(self):
        # The coordinator's release registration requires these names.
        cli, enclave = DOCUMENT["swiftProducts"]["cli"], DOCUMENT["swiftProducts"]["enclave"]
        installer = (ROOT / "scripts/install.sh").read_text()
        for line in (f'[ -f "$flat_bin/{cli}" ]', f'[ -f "$flat_bin/{enclave}" ]',
                     f'verify_file_hash "$flat_bin/{cli}" "$binary_hash" "Binary"'):
            self.assertIn(line, installer)
        updater = (ROOT / "provider-swift/Sources/ProviderCore/Update/SelfUpdater.swift").read_text()
        self.assertIn(f'names: ["bin/{cli}"]', updater)

    def test_package_declares_the_swift_products(self):
        package = (ROOT / "provider-swift/Package.swift").read_text()
        for product in DOCUMENT["swiftProducts"].values():
            self.assertIn(f'.executable(name: "{product}"', package)

    def test_environments_share_no_path_port_label_or_keychain_prefix(self):
        # Dev reads the production model CDN on purpose.
        for field in GENERATOR.FIELDS:
            if field != "modelCDNURL":
                with self.subTest(field=field):
                    self.assertNotEqual(PROD[field], DEV[field])
        for field in ("installDirectoryName", "configDirectoryName"):
            self.assertNotEqual(Path(DEV[field]).parts[:len(Path(PROD[field]).parts)], Path(PROD[field]).parts)
            self.assertNotEqual(Path(PROD[field]).parts[:len(Path(DEV[field]).parts)], Path(DEV[field]).parts)
        self.assertNotIn(DEV["configDirectoryName"], PROD["legacyConfigDirectoryNames"])
        self.assertEqual(PROD["modelCDNURL"], DEV["modelCDNURL"])

    def test_swift_tests_pin_the_json_values(self):
        tests = (ROOT / "provider-swift/Tests/ProviderCoreTests/Config/BuildEnvironmentTests.swift").read_text()
        environments = {"prod": PROD, "dev": DEV}
        pinned = re.findall(r"#expect\((?:BuildEnvironment\.)?(prod|dev)\.(\w+) == (.+)\)\n", tests)
        urls = {"coordinatorHTTPURL", "coordinatorWebSocketURL", "modelCDNURL"}
        self.assertLessEqual(set(GENERATOR.FIELDS) - urls, {field for name, field, _ in pinned if name == "prod"})
        self.assertEqual({field for name, field, _ in pinned if name == "dev"}, set(GENERATOR.FIELDS))
        for name, field, literal in pinned:
            with self.subTest(name=name, field=field):
                self.assertEqual(json.loads(literal), environments[name][field])


if __name__ == "__main__":
    unittest.main()
