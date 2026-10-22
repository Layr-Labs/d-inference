import copy
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import phase_sidecar_remote_reader as remote
from retrieve_phase_sidecar import retrieve
from retrieval_test_fixture import encoded, make_run, make_response, response_bytes
from sidecar_contract import admit_run, decode_response, remote_location
from sidecar_files import MAX_SIDECAR, parse, sha


class RetrievalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name).resolve()
        self.run, self.receipt, self.pin = make_run(self.folder)
        self.context = admit_run(self.run, self.pin)
        self.guards = [patch('subprocess.Popen', side_effect=AssertionError('No processes in tests')),
                       patch('subprocess.run', side_effect=AssertionError('No processes in tests')),
                       patch('socket.socket', side_effect=AssertionError('No sockets in tests'))]
        for guard in self.guards:
            guard.start()
    def tearDown(self):
        for guard in reversed(self.guards):
            guard.stop()
        self.temp.cleanup()
    def save_receipt(self, receipt):
        raw = encoded(receipt)
        (self.run / 'receipt.json').write_bytes(raw)
        return sha(raw)
    def fake_reader(self, host, path, payload):
        self.assertEqual((host, path), (self.context['host'], self.context['remote_path']))
        self.assertIn('os.O_NOFOLLOW', payload)
        metadata, raw = make_response(self.context)
        return response_bytes(metadata, raw), b'', dict(local_reader_ssh_client_reaped=True,
            local_reader_ssh_client_pid=888, remote_process_reaping_verified=False)
    def test_success_preserves_exact_raw_mode_and_identity(self):
        result = retrieve(self.run, self.pin, self.folder / 'out', reader=self.fake_reader)
        self.assertTrue(result['passed'])
        metadata, raw = make_response(self.context)
        self.assertEqual((self.folder / 'out/phase-trace.json').read_bytes(), raw)
        self.assertEqual(stat.S_IMODE((self.folder / 'out/phase-trace.json').stat().st_mode), 0o600)
        self.assertEqual(result['sidecar']['sha256'], metadata['sha256'])
        self.assertFalse(result['numerical_or_timing_semantics_audited'])
        self.assertFalse(result['remote_process_reaping_verified'])
    def test_existing_output_directory_and_symlink_refused(self):
        out = self.folder / 'out'
        out.mkdir()
        with self.assertRaises(FileExistsError):
            retrieve(self.run, self.pin, out, reader=self.fake_reader)
        link = self.folder / 'link'
        link.symlink_to(out)
        with self.assertRaises(FileExistsError):
            retrieve(self.run, self.pin, link, reader=self.fake_reader)
    def test_wrong_receipt_pin_prevents_reader(self):
        result = retrieve(self.run, 'f' * 64, self.folder / 'out', reader=lambda *args: self.fail('Reader called'))
        self.assertFalse(result['passed'])
        self.assertNotIn('ssh', result)
    def test_failed_or_unreaped_launcher_rejected(self):
        for key in ('passed', 'phase_timing_requested'):
            value = copy.deepcopy(self.receipt)
            value[key] = False
            with self.assertRaises(ValueError):
                admit_run(self.run, self.save_receipt(value))
        value = copy.deepcopy(self.receipt)
        value['execution']['local_ssh_client_reaped'] = False
        with self.assertRaises(ValueError):
            admit_run(self.run, self.save_receipt(value))
    def test_cleanup_or_native_error_rejected(self):
        for mutate in (lambda v: v.update(cleanup_errors=['error']),
                       lambda v: v['execution'].update(exit_code=1)):
            value = copy.deepcopy(self.receipt)
            mutate(value)
            with self.assertRaises(ValueError):
                admit_run(self.run, self.save_receipt(value))
    def test_archive_and_native_pin_changes_rejected(self):
        for relative in ('native/stdout.jsonl', 'launcher/launch_remote_long_solo.py', 'source-manifest.json'):
            path = self.run / relative
            original = path.read_bytes()
            path.write_bytes(original + b'\n')
            with self.assertRaises(ValueError):
                admit_run(self.run, self.pin)
            path.write_bytes(original)
    def test_integer_fields_reject_float_or_boolean_equivalents(self):
        value = copy.deepcopy(self.receipt)
        value['execution']['validated_outer_records'] = 2.0
        with self.assertRaises(ValueError):
            admit_run(self.run, self.save_receipt(value))
        value = copy.deepcopy(self.receipt)
        value['launcher_files'][0]['size_bytes'] = float(value['launcher_files'][0]['size_bytes'])
        with self.assertRaises(ValueError):
            admit_run(self.run, self.save_receipt(value))
        original = (self.run / 'native/stdout.jsonl').read_bytes()
        for index, invalid in [(0, True), (1, 1.0)]:
            rows = [parse(raw) for raw in original.splitlines()]
            rows[index]['schemaVersion'] = invalid
            changed = b''.join(encoded(row) for row in rows)
            (self.run / 'native/stdout.jsonl').write_bytes(changed)
            value = copy.deepcopy(self.receipt)
            for entry in value['native_files']:
                if entry['path'] == 'native/stdout.jsonl':
                    entry.update(sha256=sha(changed), size_bytes=len(changed))
            with self.assertRaises(ValueError):
                admit_run(self.run, self.save_receipt(value))
    def test_unsafe_host_and_unowned_path_refused(self):
        for mutate in (lambda v: v.update(execution_host='-oProxyCommand=bad'),
                       lambda v: v['remote_paths'].update(native='/tmp/other'),
                       lambda v: v['remote_paths'].update(root='/tmp/../tmp/owned-test')):
            value = copy.deepcopy(self.receipt)
            mutate(value)
            with self.assertRaises(ValueError):
                remote_location(value)
    def test_response_corruption_and_wrong_mode_path_refused(self):
        metadata, raw = make_response(self.context)
        for key, wrong in [('mode', 0o644), ('path', '/tmp/other/phase-trace.json'),
                           ('sha256', '0' * 64), ('size_bytes', len(raw) + 1), ('link_count', 2)]:
            value = dict(metadata, **{key: wrong})
            with self.assertRaises(ValueError):
                decode_response(response_bytes(value, raw), self.context)
    def test_mismatched_request_or_injected_clock_refused(self):
        metadata, raw = make_response(self.context)
        for mutate in (lambda t: t['identity'].update(requestFingerprint='f' * 64),
                       lambda t: t['identity'].update(role='rank0'),
                       lambda t: t.update(clockSource='injected_test_clock')):
            trace = parse(raw)
            mutate(trace)
            changed = encoded(trace)
            value = dict(metadata, sha256=sha(changed), size_bytes=len(changed))
            with self.assertRaises(ValueError):
                decode_response(response_bytes(value, changed), self.context)
    def test_duplicate_nonfinite_and_oversized_response_refused(self):
        for raw in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":1e999}'):
            with self.assertRaises(ValueError):
                parse(raw)
        with self.assertRaises(ValueError):
            decode_response(b'x' * (MAX_SIDECAR + 4098), self.context)
    def test_local_mutation_during_read_fails_postcheck(self):
        def reader(*args):
            result = self.fake_reader(*args)
            (self.run / 'native/stdout.jsonl').write_bytes(b'changed')
            return result
        result = retrieve(self.run, self.pin, self.folder / 'out', reader=reader)
        self.assertFalse(result['passed'])
        self.assertIn('Pinned native file differs', result['primary_failure']['error'])
    def remote_file(self, data=b'{"fixture":true}\n'):
        path = self.folder / 'phase-trace.json'
        path.write_bytes(data)
        path.chmod(0o600)
        return path
    def test_remote_reader_stable_exact_mode_bytes(self):
        path = self.remote_file()
        before = path.stat()
        metadata, raw = remote.read_sidecar(str(path))
        self.assertEqual(raw, path.read_bytes())
        self.assertEqual(metadata['sha256'], sha(raw))
        self.assertEqual(metadata['mode'], 0o600)
        self.assertEqual(remote.signature(before), remote.signature(path.stat()))
    def test_remote_reader_leaf_and_parent_symlinks_refused(self):
        path = self.remote_file()
        actual = self.folder / 'actual'
        path.rename(actual)
        path.symlink_to(actual)
        with self.assertRaises(OSError):
            remote.read_sidecar(str(path))
        path.unlink()
        path.write_bytes(b'x')
        path.chmod(0o600)
        link = self.folder / 'linked-parent'
        link.symlink_to(self.folder, target_is_directory=True)
        with self.assertRaises(OSError):
            remote.read_sidecar(str(link / 'phase-trace.json'))
    def test_remote_reader_missing_wrongmode_empty_oversized_refused(self):
        with self.assertRaises(OSError):
            remote.read_sidecar(str(self.folder / 'phase-trace.json'))
        path = self.remote_file()
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            remote.read_sidecar(str(path))
        path.chmod(0o600)
        for raw in (b'', b'x' * (MAX_SIDECAR + 1)):
            path.write_bytes(raw)
            with self.assertRaises(ValueError):
                remote.read_sidecar(str(path))
    def test_remote_reader_growth_detected_without_partial_publication(self):
        path = self.remote_file()
        original_read = os.read
        changed = False
        def read(descriptor, count):
            nonlocal changed
            raw = original_read(descriptor, count)
            if not changed:
                changed = True
                with path.open('ab') as stream:
                    stream.write(b'x')
            return raw
        with patch.object(remote.os, 'read', side_effect=read), self.assertRaises(ValueError):
            remote.read_sidecar(str(path))


if __name__ == '__main__':
    unittest.main()
