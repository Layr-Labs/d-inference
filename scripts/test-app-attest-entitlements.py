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

    def test_macos_opt_in_array_does_not_require_environment_grant(self):
        # Shape observed in the regenerated Developer ID profile. No profile
        # certificate, UUID, or user-specific data is needed in this fixture.
        base = {"com.apple.developer.aps-environment": "production",
                "keychain-access-groups": ["TEAM.app"]}
        profile = {"Entitlements": {MODULE.OPT_IN: ["CDhash"]}}
        result, configured = MODULE.prepare(base, profile)
        self.assertTrue(configured)
        self.assertEqual(result[MODULE.OPT_IN], ["CDhash"])
        self.assertNotIn(MODULE.ENVIRONMENT, result)
        self.assertEqual({key: result[key] for key in base}, base)
        # Re-running preparation must not mutate the profile's grant array.
        result[MODULE.OPT_IN].append("changed")
        self.assertEqual(profile["Entitlements"][MODULE.OPT_IN], ["CDhash"])

    def test_opt_in_string_and_array_preserve_their_types(self):
        for grant in ["CDhash", ["CDhash", "future-mode"]]:
            with self.subTest(grant=grant):
                result, configured = MODULE.prepare(
                    {"com.apple.developer.aps-environment": "production"},
                    {"Entitlements": {MODULE.OPT_IN: grant}})
                self.assertTrue(configured)
                self.assertEqual(result[MODULE.OPT_IN], "CDhash" if isinstance(grant, str) else ["CDhash"])

    def test_unrecognized_opt_in_is_not_configured(self):
        for grant in [None, True, "*", [], ["future-mode"], ["CDhash", True], {"CDhash": True}]:
            with self.subTest(grant=grant):
                result, configured = MODULE.prepare(
                    {"com.apple.developer.aps-environment": "production"},
                    {"Entitlements": {MODULE.OPT_IN: grant}})
                self.assertFalse(configured)
                self.assertNotIn(MODULE.OPT_IN, result)


if __name__ == "__main__":
    unittest.main()
