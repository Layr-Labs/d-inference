import json
import tempfile
import unittest
from pathlib import Path

from . import catalog_codegen as catalog


class DeadlineCatalogCodegenTests(unittest.TestCase):
    def test_checked_in_generated_sources_are_exact(self):
        self.assertEqual(catalog.sync(check=True), [])

    def test_reviewed_values_survive_both_source_literal_formats(self):
        # Literal-escaping fixture only; this deliberately is not a promotable
        # serving profile and is never written to the reviewed catalog.
        rows = [{"id": 'quote"# and \\#(interpolation) ` λ',
                 "rate": 1234.56789, "count": 9007199254740993,
                 "optional": None, "nested": [True, 0.95]}]
        sources = catalog.rendered_sources(json.dumps(rows).encode())
        go_literal = sources[catalog.GO].split("const reviewedDeadlineProfilesJSON = ", 1)[1].strip()
        go_json = json.loads(go_literal)
        swift_literal = sources[catalog.SWIFT].split("static let json = ", 1)[1].splitlines()[0]
        hashes = swift_literal[:swift_literal.index('"')]
        self.assertGreater(len(hashes), 1)
        swift_json = swift_literal[len(hashes) + 1:-(len(hashes) + 1)]
        self.assertEqual(swift_json, go_json)
        self.assertEqual(json.loads(swift_json), rows)
        self.assertEqual(sources, catalog.rendered_sources(json.dumps(rows, indent=4).encode()))

    def test_ambiguous_or_nonfinite_catalog_is_rejected(self):
        for raw in ('{}', 'null', '[null]', '[{"id":""}]',
                    '[{"id":"x"},{"id":"x"}]', '[{"id":"x","id":"y"}]',
                    '[{"id":"x","rate":NaN}]', '[{"id":"x","rate":1e999}]'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                catalog.rendered_sources(raw)

    def test_check_refuses_drift_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / catalog.SOURCE).parent.mkdir(parents=True)
            (root / catalog.SOURCE).write_text("[]\n")
            catalog.sync(root)
            (root / catalog.SWIFT).write_text("stale")
            with self.assertRaisesRegex(ValueError, "differs"):
                catalog.sync(root, check=True)
            self.assertEqual((root / catalog.SWIFT).read_text(), "stale")
            catalog.sync(root)
            self.assertEqual(catalog.sync(root, check=True), [])


if __name__ == "__main__":
    unittest.main()
