"""Synthetic local archives exercise replay without committing hardware data."""
import json
from pathlib import Path
import tempfile
import unittest
import uuid

from .catalog_codegen import ROOT as REPO_ROOT
from .catalog_evidence import canonical_profile_sha256, replay_catalog_evidence, validate_evidence_index
from .check_receipt_fixtures import ROOT as ARCHIVE_ROOT
from .deadline_profile import evaluate_deadline_profile
from .deadline_receipt_fixtures import receipt


def index_entry(profile, relative):
    return dict(receipt=relative, profile_id=profile["id"],
                qualification_report_sha256=profile["qualification_report_sha256"],
                profile_sha256=canonical_profile_sha256(profile))


class CatalogEvidencePathsTests(unittest.TestCase):
    def test_external_archive_replays_actual_raw_runs_and_requires_exact_catalog(self):
        self.assertFalse(ARCHIVE_ROOT.resolve().is_relative_to(REPO_ROOT.resolve()))
        relative = f"review-{uuid.uuid4().hex}.json"
        raw = json.dumps(receipt()).encode()
        path = ARCHIVE_ROOT / relative
        path.write_bytes(raw)
        self.addCleanup(path.unlink)
        result = evaluate_deadline_profile(raw, evidence_root=ARCHIVE_ROOT)
        self.assertTrue(result["qualified"], result["errors"])
        reviewed, index = [result["profile"]], [index_entry(result["profile"], relative)]
        self.assertEqual(replay_catalog_evidence(reviewed, index, ARCHIVE_ROOT), reviewed)
        reviewed[0] = dict(reviewed[0], id="different-reviewed-profile")
        # Even if somebody edits both the catalog and its metadata binding,
        # actual replay must still reject disagreement with the qualified raw data.
        index = [index_entry(reviewed[0], relative)]
        with self.assertRaisesRegex(ValueError, "exactly match"):
            replay_catalog_evidence(reviewed, index, ARCHIVE_ROOT)

    def test_missing_index_and_legacy_repository_root_fail_without_an_archive(self):
        for reviewed, index in [([{"id": "fixture"}], []), ([], [{"receipt": "receipt.json"}]),
                                ([{}], [{"evidence_root": "docs/evidence", "receipt": "receipt.json"}])]:
            with self.subTest(index=index), self.assertRaises(ValueError):
                validate_evidence_index(reviewed, index)
        self.assertEqual(replay_catalog_evidence([], [], None), [])
        profile = dict(id="fixture", qualification_report_sha256="a" * 64)
        with self.assertRaisesRegex(ValueError, "explicit local evidence root"):
            replay_catalog_evidence([profile], [index_entry(profile, "receipt.json")], None)

    def test_archive_paths_cannot_escape_by_absolute_parent_or_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "archive"
            root.mkdir()
            outside = Path(temporary) / "outside.json"
            outside.write_text("{}")
            (root / "linked.json").symlink_to(outside)
            profile = dict(id="fixture", qualification_report_sha256="a" * 64)
            for relative in (str(outside), "../outside.json", "linked.json"):
                with self.subTest(path=relative), self.assertRaises(ValueError):
                    replay_catalog_evidence([profile], [index_entry(profile, relative)], root)


if __name__ == "__main__":
    unittest.main()
