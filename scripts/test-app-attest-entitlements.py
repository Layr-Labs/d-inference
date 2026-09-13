#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("prepare", Path(__file__).with_name("prepare-app-attest-entitlements.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AppAttestSigningTests(unittest.TestCase):
    def test_legacy_profile_preserves_apns_and_keychain(self):
        base = {"com.apple.developer.aps-environment": "production", "keychain-access-groups": ["TEAM.app"]}
        result, configured = MODULE.prepare(base, {"Entitlements": {}})
        self.assertFalse(configured)
        self.assertEqual(result, base)

    def test_only_profile_authorized_grants_are_added(self):
        base = {"com.apple.developer.aps-environment": "production"}
        for grant in ["production", "*", ["development", "production"]]:
            result, configured = MODULE.prepare(base, {"Entitlements": {MODULE.ENVIRONMENT: grant, MODULE.OPT_IN: "CDhash"}})
            self.assertTrue(configured)
            self.assertEqual(result[MODULE.ENVIRONMENT], "production")
            self.assertEqual(result[MODULE.OPT_IN], "CDhash")
            self.assertEqual(result["com.apple.developer.aps-environment"], "production")
        for grant in [None, "development", True, {}, ["development"]]:
            result, configured = MODULE.prepare(base, {"Entitlements": {MODULE.ENVIRONMENT: grant}})
            self.assertFalse(configured)
            self.assertNotIn(MODULE.ENVIRONMENT, result)

    def test_does_not_copy_unrelated_private_entitlement(self):
        result, _ = MODULE.prepare({"com.apple.developer.aps-environment": "production"}, {"Entitlements": {
            MODULE.ENVIRONMENT: "production", "com.apple.devicecheck.daemon-client": True}})
        self.assertNotIn("com.apple.devicecheck.daemon-client", result)

    def test_removing_apns_is_an_error(self):
        with self.assertRaises(ValueError):
            MODULE.prepare({}, {"Entitlements": {MODULE.ENVIRONMENT: "production"}})


if __name__ == "__main__":
    unittest.main()
