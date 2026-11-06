import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import hashlib

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE / 'source/package'))
sys.path.insert(0, str(BASE / 'source'))
from jaccl_startup_stderr import JacclStartupProgress, LINES, MAX_BYTES, validate_retained
from worker_contract import WorkerSpec
from worker_processes import PipeWorkers
import reference_binding


class StartupStderr(unittest.TestCase):
    def test_exact_prefixes(self):
        self.assertEqual(MAX_BYTES, 180)
        for count in range(5):
            value = validate_retained(b''.join(LINES[:count]), 'stage1')
            self.assertEqual(value['completedLines'], count)
            self.assertFalse(value['connectionSuccessEstablished'])

    def test_fragmented_and_coalesced(self):
        parser = JacclStartupProgress()
        for byte in LINES[0]:
            parser.feed(bytes([byte]))
        parser.feed(b''.join(LINES[1:])); parser.finish()
        self.assertEqual(parser.summary()['bytes'], 180)

    def test_unknown_or_terminal_error(self):
        for raw in [b'[jaccl] Couldn\'t connect (error: 60)\n', b'warning\n',
                    LINES[0].replace(b'1000', b'1001'), LINES[0].replace(b'\n', b'\r\n'),
                    LINES[0] + b'darkbloom-cluster-worker: failure\n']:
            with self.assertRaises(ValueError): validate_retained(raw, 'stage1')

    def test_partial_eof(self):
        for end in range(1, len(LINES[0])):
            with self.assertRaises(ValueError): validate_retained(LINES[0][:end], 'stage1')

    def test_duplicate_skip_order_extra(self):
        for raw in [LINES[0] * 2, LINES[1], LINES[0] + LINES[2],
                    b''.join(LINES) + LINES[0], b''.join(reversed(LINES))]:
            with self.assertRaises(ValueError): validate_retained(raw, 'stage1')

    def test_strict_roles_and_eof_state(self):
        for mode in ('full', 'stage0'):
            self.assertEqual(validate_retained(b'', mode)['bytes'], 0)
            with self.assertRaises(ValueError): validate_retained(LINES[0], mode)
        parser = JacclStartupProgress(); parser.finish()
        with self.assertRaises(ValueError): parser.finish()
        with self.assertRaises(ValueError): parser.feed(LINES[0])

    def child(self, chunks, *, result=True, exit_code=0, accepted=True, policy=True):
        script = ('import os,time\n' + ''.join('os.write(2,%r)\ntime.sleep(.005)\n' % c for c in chunks)
                  + ('os.write(1,b\'{"done":true}\\n\')\n' if result else '')
                  + 'raise SystemExit(%d)\n' % exit_code)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve() / 'native'
            parser = JacclStartupProgress() if policy else None
            spec = WorkerSpec((sys.executable, '-B', '-c', script),
                              dict(PATH='/usr/bin:/bin', HOME=str(Path.home())), 'solo', None)
            pipes = PipeWorkers((spec,), directory, 3, lambda _: None, stderr_policy=parser)
            passed = False
            failure = None
            try:
                pipes.start()
                def check(_, raw):
                    self.assertEqual(json.loads(raw), {'done': True})
                    return True
                self.assertEqual(pipes.collect('fixture-result', check), [True])
                pipes.finish()
                passed = True
            except ValueError as error:
                failure = str(error)
            finally:
                pipes.close(kill=not passed)
            self.assertEqual(passed, accepted, failure)
            self.assertTrue(all(p.returncode is not None for p in pipes.children))
            for child in pipes.children:
                with self.assertRaises(ProcessLookupError): os.killpg(child.pid, 0)
            if accepted:
                self.assertTrue(pipes.complete_output)
                self.assertEqual(pipes.cleanup_errors, [])
                self.assertEqual((directory / 'worker-0.stderr').read_bytes(), b''.join(chunks))
                self.assertEqual(parser.summary(), validate_retained(b''.join(chunks), 'stage1'))
            else:
                self.assertIsNotNone(failure)
                # Failed cleanup diagnostics remain evidence; EPERM is not
                # converted into success or treated as proof of group absence.

    def test_owned_fragmented_success(self):
        self.child([LINES[0][:9], LINES[0][9:], b''.join(LINES[1:])])

    def test_owned_unknown_stderr(self):
        self.child([LINES[0], b'unknown\n'], accepted=False)

    def test_owned_final_connect_error(self):
        self.child([b''.join(LINES), b"[jaccl] Couldn't connect (error: 60)\n"], accepted=False)

    def test_owned_partial_eof(self):
        self.child([LINES[0][:-1]], accepted=False)

    def test_owned_result_still_required(self):
        self.child([LINES[0]], result=False, accepted=False)

    def test_owned_nonzero_still_fails(self):
        self.child([LINES[0]], exit_code=1, accepted=False)

    def test_owned_default_remains_strict(self):
        self.child([LINES[0]], accepted=False, policy=False)

    def test_reference_binding_and_terminal_join(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            old = root / 'old'; current = root / 'current'; returned = root / 'returned'
            for directory in (old, current, returned): directory.mkdir()
            def save(path, value):
                raw = json.dumps(value).encode(); path.write_bytes(raw)
                return hashlib.sha256(raw).hexdigest()
            binding = dict(nativeSHA256='a' * 64, expectedSHA256='b' * 64)
            old_sha = save(old / 'binding-receipt.json', dict(binding=binding))
            save(old / 'binding.json', binding); save(current / 'binding.json', binding)
            terminal_sha = save(returned / 'terminal.json', dict(status='completed'))
            collection_sha = save(root / 'returned-collection.json', dict(files=['terminal.json']))
            with patch.multiple(reference_binding, FULL_BOUND=old, FULL_DIRECTORY=returned,
                                FULL_BINDING_SHA=old_sha, FULL_TERMINAL_SHA=terminal_sha,
                                FULL_COLLECTION_SHA=collection_sha):
                self.assertEqual(reference_binding.reference_bound(current, returned), old)
                save(current / 'binding.json', dict(binding, expectedSHA256='c' * 64))
                with self.assertRaises(ValueError): reference_binding.reference_bound(current, returned)
                save(current / 'binding.json', binding)
                save(returned / 'terminal.json', dict(status='failed'))
                with self.assertRaises(ValueError): reference_binding.reference_bound(current, returned)


if __name__ == '__main__': unittest.main()
