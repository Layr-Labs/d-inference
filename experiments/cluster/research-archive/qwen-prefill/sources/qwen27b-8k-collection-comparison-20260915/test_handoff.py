"""Small file/packet/transport checks; fabricated payloads are never model evidence."""
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import prepare_packet as helper

helper.bootstrap()
from audit_generation import write_result
import collect_sidecars as collector
from collect_sidecars import decode_response
from read_sidecar_remote import read_fixed, SIDECAR


class HandoffChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from audit_common import request_context
        from audit_scope import pinned_scope
        import fabricated
        request = json.loads((helper.PARENT / 'inputs/request.json').read_bytes())
        plan = json.loads((helper.PARENT / 'provenance/recording-metadata.json').read_bytes())
        scope = pinned_scope(request, plan)
        context = request_context((helper.PARENT / 'inputs/prompt.ids.json').read_bytes(), request['requestID'], scope)
        with patch.object(fabricated, 'request_context', return_value=context):
            _, _, admitted, report, _, _ = fabricated.fixture(scope, request['requestID'])
        cls.reference = fabricated.reference_bytes(admitted, report)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.paths = [self.root / name for name in ['reference', 'rank0', 'rank1']]
        for i, path in enumerate(self.paths):
            path.write_bytes(('fabricated opaque artifact ' + str(i)).encode())
        self.paths[0].write_bytes(self.reference)
        self.pins = [helper.digest(path) for path in self.paths]

    def tearDown(self):
        self.temporary.cleanup()

    def packet(self, ranks=None):
        return helper.assemble(self.paths[0], self.pins[0], ranks or list(zip(self.paths[1:], self.pins[1:])))

    def response(self):
        raw = b'fabricated transport bytes'
        return {'schema': 'qwen27b_sidecar_collection_v1', 'path': SIDECAR, 'bytes': len(raw),
            'sha256': hashlib.sha256(raw).hexdigest(), 'identity': [1,2,33152,len(raw),5,6],
            'data': base64.b64encode(raw).decode(), 'active': [], 'journalBytes': 0,
            'journalSHA256': hashlib.sha256(b'').hexdigest(), 'journalIdentity': [1,3,33152,0,5,6]}

    def test_six_roles_exact_prepared_agreement(self):
        packet = self.packet()
        self.assertEqual(set(packet['files']), {'prompt', 'reference_stdout', 'rank0_evidence',
                                              'rank1_evidence', 'registered_request', 'registered_plan'})
        self.assertEqual(packet['expected_agreement'], json.loads((helper.PARENT/'expected-agreement.json').read_bytes()))
        self.assertEqual(packet['request_id'], 'c7517799-2a77-49fa-af9c-2b4f662bf76c')

    def test_wrong_supplied_hash_refused(self):
        with self.assertRaises(ValueError):
            self.packet([(self.paths[1], '0'*64), (self.paths[2], self.pins[2])])

    def test_same_inode_roles_refused(self):
        alias = self.root / 'rank-alias'
        os.link(self.paths[1], alias)
        with self.assertRaises(ValueError):
            self.packet([(self.paths[1], self.pins[1]), (alias, self.pins[1])])

    def test_existing_packet_never_replaced(self):
        output = self.root/'packet.json'
        output.write_bytes(b'original')
        with self.assertRaises(FileExistsError):
            write_result(output, self.packet())
        self.assertEqual(output.read_bytes(), b'original')

    def test_transport_content_hash_and_path(self):
        value = self.response()
        data, meta = decode_response(json.dumps(value).encode())
        self.assertEqual(data, b'fabricated transport bytes')
        self.assertNotIn('data', meta)
        for key, replacement in [('path','/tmp/wrong'), ('sha256','0'*64), ('bytes',True),
                                  ('journalBytes',True), ('journalSHA256','0'*64)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                decode_response(json.dumps(dict(value, **{key:replacement})).encode())

    def test_remote_reader_bound_and_nofollow(self):
        data, identity = read_fixed(self.paths[1], 128)
        self.assertEqual(data, self.paths[1].read_bytes())
        self.assertEqual(identity[3], len(data))
        with self.assertRaises(AssertionError): read_fixed(self.paths[0], 1)
        link = self.root/'link';link.symlink_to(self.paths[0])
        with self.assertRaises(OSError): read_fixed(link, 128)

    def test_remote_reader_empty_only_journal(self):
        empty = self.root/'empty';empty.touch()
        self.assertEqual(read_fixed(empty, 128, empty=True)[0], b'')
        with self.assertRaises(AssertionError): read_fixed(empty, 128)

    def collection(self, responses):
        output = self.root/'collection'
        def fake_digest(path):
            if path.name == 'known_hosts':
                return '89a73d7ca9fe16a0c1aeb0fa6cfa640ff37a02d4a2d21114e7ad5fca089443ed'
            return helper.digest(path)
        with patch.object(collector, 'bootstrap'), patch.object(collector, 'digest', side_effect=fake_digest), \
             patch.object(subprocess, 'run', side_effect=responses), \
             patch.object(sys, 'argv', ['collect_sidecars.py', '--output-directory', str(output)]), \
             contextlib.redirect_stdout(io.StringIO()):
            code = collector.main()
        return code, output, json.loads((output/'collection.json').read_bytes())

    def completed(self, value=None):
        return subprocess.CompletedProcess([], 0, json.dumps(value or self.response()).encode(), b'')

    def test_collection_retains_refused_postflight(self):
        first = self.response();first['active'] = ['123 cluster-inference']
        code, output, receipt = self.collection([self.completed(first), self.completed()])
        self.assertEqual(code, 1)
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual([x['status'] for x in receipt['ranks']], ['failed', 'collected'])
        self.assertTrue((output/'rank0-evidence.json').is_file())

    def test_collection_timeout_retains_partial_output(self):
        expired = subprocess.TimeoutExpired(['mock-ssh'], 30, output=b'partial', stderr=b'context')
        code, output, receipt = self.collection([expired, self.completed()])
        self.assertEqual(code, 1)
        self.assertEqual((output/'rank0.transport.stdout').read_bytes(), b'partial')
        self.assertFalse((output/'rank0-evidence.json').exists())
        self.assertEqual(receipt['ranks'][1]['status'], 'collected')

    def test_collection_interrupt_cannot_report_success(self):
        code, _, receipt = self.collection([KeyboardInterrupt()])
        self.assertEqual(code, 1)
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(len(receipt['ranks']), 1)
        self.assertIn('KeyboardInterrupt', receipt['ranks'][0]['error'])

    def test_collected_packet_roles_bind_receipt_pin(self):
        code, output, receipt = self.collection([self.completed(), self.completed()])
        self.assertEqual(code, 0)
        path = output/'collection.json'
        ranks, _ = helper.collected_ranks(path, helper.digest(path))
        self.assertEqual([Path(row[0]).name for row in ranks], ['rank0-evidence.json', 'rank1-evidence.json'])
        with self.assertRaises(ValueError): helper.collected_ranks(path, '0'*64)
        receipt['parentManifestSHA256'] = '0'*64
        path.write_text(json.dumps(receipt))
        with self.assertRaises(ValueError): helper.collected_ranks(path, helper.digest(path))

    def test_failed_collection_cannot_prepare_packet(self):
        _, output, _ = self.collection([KeyboardInterrupt()])
        path = output/'collection.json'
        with self.assertRaises(ValueError): helper.collected_ranks(path, helper.digest(path))


if __name__ == '__main__':
    unittest.main()
