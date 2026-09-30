"""Offline CI must bind exact reviewed profiles even without hardware archives."""
import copy
import hashlib
import unittest

from .catalog_evidence import canonical_profile_sha256, validate_evidence_index
from .test_catalog_evidence_paths import index_entry


class CatalogEvidenceIndexTests(unittest.TestCase):
    def setUp(self):
        self.reviewed = [dict(id=f"fixture-{i}", qualification_report_sha256=str(i) * 64,
                              deadline_calibration={"cells": [{"prompt_tokens_max": 4096}]})
                         for i in (1, 2)]
        self.index = [index_entry(profile, f"profile-{i}/receipt.json")
                      for i, profile in enumerate(self.reviewed)]

    def test_exact_profile_bindings_validate_without_an_archive(self):
        validate_evidence_index(self.reviewed, self.index)

    def test_replacement_reordering_and_changed_bounds_cannot_reuse_index(self):
        replacements = []
        value = copy.deepcopy(self.reviewed)
        value[0]["id"] = "replacement"
        replacements.append(value)
        replacements.append(list(reversed(self.reviewed)))
        value = copy.deepcopy(self.reviewed)
        value[0]["qualification_report_sha256"] = "f" * 64
        replacements.append(value)
        value = copy.deepcopy(self.reviewed)
        value[0]["deadline_calibration"]["cells"][0]["prompt_tokens_max"] = 32768
        replacements.append(value)
        for reviewed in replacements:
            with self.subTest(reviewed=reviewed), self.assertRaisesRegex(ValueError, "exactly match"):
                validate_evidence_index(reviewed, self.index)
        with self.assertRaisesRegex(ValueError, "catalog order"):
            validate_evidence_index(self.reviewed, list(reversed(self.index)))

    def test_missing_binding_duplicate_ids_and_noncanonical_receipts_fail(self):
        for key in ("profile_id", "qualification_report_sha256", "profile_sha256"):
            index = copy.deepcopy(self.index)
            del index[0][key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_evidence_index(self.reviewed, index)
        duplicated = [self.reviewed[0], self.reviewed[0]]
        with self.assertRaisesRegex(ValueError, "unique ids"):
            validate_evidence_index(duplicated, [index_entry(duplicated[0], "a.json"),
                                                index_entry(duplicated[1], "b.json")])
        for relative in ("./receipt.json", "a//receipt.json", "a/../receipt.json", "a/", ".",
                         "a\\receipt.json", "bad\x00.json", self.index[1]["receipt"]):
            index = copy.deepcopy(self.index)
            index[0]["receipt"] = relative
            with self.subTest(relative=relative), self.assertRaises(ValueError):
                validate_evidence_index(self.reviewed, index)

    def test_digest_uses_full_sorted_utf8_json_and_preserves_array_order(self):
        profile = {"z": [2, 1], "a": "mødèl/path", "bound": 1.25}
        expected = hashlib.sha256('{"a":"mødèl/path","bound":1.25,"z":[2,1]}'.encode("utf-8")).hexdigest()
        self.assertEqual(canonical_profile_sha256(profile), expected)
        self.assertEqual(canonical_profile_sha256(dict(reversed(list(profile.items())))), expected)
        self.assertNotEqual(canonical_profile_sha256(dict(profile, z=[1, 2])), expected)
        with self.assertRaises(ValueError):
            canonical_profile_sha256(dict(profile, bound=float("nan")))


if __name__ == "__main__":
    unittest.main()
