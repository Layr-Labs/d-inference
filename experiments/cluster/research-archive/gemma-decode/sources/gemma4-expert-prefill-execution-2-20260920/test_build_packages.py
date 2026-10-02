"""Pure source-package metadata controls; no compiler, model or binary reads."""
import copy
import json
import unittest
from build_binding import ROOT, source_package


class BuildPackages(unittest.TestCase):
    def setUp(self):
        self.reference=json.loads((ROOT/'binding-inputs.json').read_text())['prefillSource']
        self.name='gemma4-expert-prefill-bound-20260920'
        self.row=dict(name=self.name,integrationSHA256=self.reference['sha256'])

    def test_original_two_field_identity_still_matches(self):
        source_package([self.row],self.name,self.reference)

    def test_optional_exact_manifest_is_verified(self):
        row=dict(self.row,manifestSHA256=self.reference['manifestSHA256'])
        source_package([row],self.name,self.reference)

    def test_missing_duplicate_or_unknown_fields_refused(self):
        for rows in ([],[self.row,self.row],[dict(self.row,unreviewed=True)]):
            with self.assertRaises(ValueError):source_package(rows,self.name,self.reference)

    def test_changed_integration_or_manifest_refused(self):
        for field in ('integrationSHA256','manifestSHA256'):
            row=dict(self.row,manifestSHA256=self.reference['manifestSHA256']);row[field]='0'*64
            with self.assertRaises(ValueError):source_package([row],self.name,self.reference)


if __name__=='__main__':unittest.main()
