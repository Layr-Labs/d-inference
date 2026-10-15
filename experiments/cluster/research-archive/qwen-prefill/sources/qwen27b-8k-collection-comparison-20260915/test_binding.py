"""Exercise the changed manifest adapter without native or remote execution."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from prepare_packet import verify_package


class ManifestChecks(unittest.TestCase):
    def test_both_pinned_membership_shapes_and_tamper(self):
        for dictionary in (False, True):
            with self.subTest(dictionary=dictionary), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                member = root / 'member'; member.write_bytes(b'private fixture')
                pin = dict(bytes=member.stat().st_size, sha256=hashlib.sha256(member.read_bytes()).hexdigest())
                members = {'member': pin} if dictionary else [dict(path='member', **pin)]
                manifest = root / 'manifest.json'
                manifest.write_text(json.dumps(dict(files=members)))
                expected = hashlib.sha256(manifest.read_bytes()).hexdigest()
                verify_package(root, expected)
                member.write_bytes(b'private fixturE')
                with self.assertRaises(ValueError):
                    verify_package(root, expected)


if __name__ == '__main__':
    unittest.main()
