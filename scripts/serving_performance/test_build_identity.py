import copy
import unittest

from .build_identity import verified_build_identity
from .test_deadline_receipts import assemble, run


class BuildIdentityTests(unittest.TestCase):
    def test_running_release_identity_is_required_and_bound_to_binary(self):
        report, provenance = run("calibration")
        self.assertEqual(verified_build_identity(report, provenance), report["buildIdentity"])
        for mutation in ("missing", "debug", "assertions", "binary", "claimed_config", "flag_type"):
            changed, facts = copy.deepcopy(report), copy.deepcopy(provenance)
            if mutation == "missing": changed.pop("buildIdentity")
            elif mutation == "debug": changed["buildIdentity"]["debugCompilationCondition"] = True
            elif mutation == "assertions": changed["buildIdentity"]["debugAssertionsEnabled"] = True
            elif mutation == "binary": changed["buildIdentity"]["binarySHA256"] = "a" * 64
            elif mutation == "claimed_config": facts["build_configuration"] = "debug"
            else: changed["buildIdentity"]["debugCompilationCondition"] = 0
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                assemble((changed, facts))

    def test_cli_release_label_and_old_false_flag_cannot_certify_debug_binary(self):
        report, provenance = run("calibration")
        report["buildIdentity"]["debugCompilationCondition"] = True
        provenance["build_configuration"] = "release"
        provenance["debug_compilation_condition"] = False
        with self.assertRaises(ValueError):
            verified_build_identity(report, provenance)
        self.assertTrue(verified_build_identity(report, provenance, require_release=False)["debugCompilationCondition"])
