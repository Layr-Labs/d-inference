"""Real temporary-file CPU regressions; no native/model or historical inputs."""

from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import binding_inputs
from binding_inputs import Inputs, snapshot


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def packet_files(folder):
    contents = dict(stdout=b'fabricated\n', stderr=b'', prompt=b'[1,2,3]', teacher=b'[4]',
                    parent=b'{}', numerical=b'{}', source_manifest=b'{}',
                    bundle_manifest=b'{}', retained_metadata=b'{}')
    refs = {}
    for role, raw in contents.items():
        path = folder / (role + '.json')
        path.write_bytes(raw)
        refs[role] = dict(path=path.name, sha256=digest(raw))
    packet = dict(schema='private_short_execution_binding_packet_v1',
                  profile='registered_qwen35_9b', files=refs,
                  source_files=[], bundle_files=[], private_files=[])
    path = folder / 'packet.json'
    path.write_text(json.dumps(packet))
    return path, packet, contents


class ReadWrapper:
    def __init__(self, stream, after_read=None):
        self.stream, self.after_read, self.requests = stream, after_read, []

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return self.stream.__exit__(*args)

    def fileno(self):
        return self.stream.fileno()

    def read(self, size):
        self.requests.append(size)
        value = self.stream.read(size)
        if self.after_read is not None:
            action, self.after_read = self.after_read, None
            action()
        return value


class BindingInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='binding-input-test-')
        self.folder = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def test_regular_snapshot_streams_identical_hash_without_retained_payload(self):
        raw = b'abcd' * (512 * 1024) + b'tail'
        path = self.folder / 'member'; path.write_bytes(raw)
        original = os.fdopen
        wrappers = []

        def wrapped(descriptor, mode):
            value = ReadWrapper(original(descriptor, mode)); wrappers.append(value)
            return value

        with patch.object(binding_inputs.os, 'fdopen', wrapped):
            streamed = snapshot(path, len(raw), keep=False)
        captured = snapshot(path, len(raw))
        self.assertIsNone(streamed['raw'])
        self.assertEqual(captured['raw'], raw)
        self.assertEqual({k:v for k,v in streamed.items() if k != 'raw'},
                         {k:v for k,v in captured.items() if k != 'raw'})
        self.assertEqual(streamed['sha256'], digest(raw))
        self.assertGreater(len(wrappers[0].requests), 2)
        self.assertTrue(all(0 < n <= 1024**2 for n in wrappers[0].requests))
        self.assertTrue(wrappers[0].stream.closed)

    def test_empty_opt_in_and_oversize_rejection_before_read(self):
        empty = self.folder / 'empty'; empty.write_bytes(b'')
        with self.assertRaises(ValueError):
            snapshot(empty, 1)
        self.assertEqual(snapshot(empty, 1, empty=True)['sha256'], digest(b''))
        large = self.folder / 'too-large'; large.write_bytes(b'12345')
        original = os.fdopen; wrappers = []

        def wrapped(descriptor, mode):
            value = ReadWrapper(original(descriptor, mode)); wrappers.append(value)
            return value

        with patch.object(binding_inputs.os, 'fdopen', wrapped), self.assertRaises(ValueError):
            snapshot(large, 4)
        self.assertEqual(wrappers[0].requests, [])
        self.assertTrue(wrappers[0].stream.closed)

    def test_leaf_symlink_and_directory_are_not_regular_snapshots(self):
        target = self.folder / 'target'; target.write_bytes(b'a')
        link = self.folder / 'link'; link.symlink_to(target)
        with self.assertRaises(OSError):
            snapshot(link, 10)
        with self.assertRaises((OSError, ValueError)):
            snapshot(self.folder, 10)

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'requires POSIX FIFO')
    def test_fifo_refusal_is_bounded_in_an_owned_python_child(self):
        fifo = self.folder / 'fifo'; os.mkfifo(fifo, 0o600)
        # A missing O_NONBLOCK regression must fail this test, not hang the suite.
        script = '''import sys
sys.path.insert(0, sys.argv[1])
from binding_inputs import snapshot
try:
    snapshot(sys.argv[2], 16)
except ValueError:
    print("regular-file refusal")
else:
    raise AssertionError("FIFO was accepted")
'''
        completed = subprocess.run([sys.executable, '-B', '-c', script,
                                    str(Path(binding_inputs.__file__).parent), str(fifo)],
                                   capture_output=True, timeout=3)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode())
        self.assertEqual(completed.stdout, b'regular-file refusal\n')

    def test_growth_after_first_read_cannot_cross_cap(self):
        path = self.folder / 'growing'; path.write_bytes(b'abc')
        original = os.fdopen; wrappers = []

        def append():
            with path.open('ab') as stream:
                stream.write(b'd')

        def wrapped(descriptor, mode):
            value = ReadWrapper(original(descriptor, mode), append); wrappers.append(value)
            return value

        with patch.object(binding_inputs.os, 'fdopen', wrapped), \
                self.assertRaisesRegex(ValueError, 'grew beyond'):
            snapshot(path, 3)
        self.assertTrue(wrappers[0].stream.closed)

    def test_mutation_after_bytes_before_final_fstat_is_rejected(self):
        path = self.folder / 'changing'; path.write_bytes(b'abc')
        original = os.fstat; calls = []

        def observed(descriptor):
            calls.append(descriptor)
            if len(calls) == 2:
                path.write_bytes(b'xyz')
            return original(descriptor)

        with patch.object(binding_inputs.os, 'fstat', observed), \
                self.assertRaisesRegex(ValueError, 'changed during snapshot'):
            snapshot(path, 16)
        self.assertEqual(len(calls), 2)

    def test_core_relative_snapshots_metadata_and_recheck(self):
        path, _, contents = packet_files(self.folder)
        inputs = Inputs(path)
        self.assertEqual(inputs.core['prompt']['raw'], contents['prompt'])
        self.assertEqual(inputs.metadata()['teacher'],
                         dict(sha256=digest(contents['teacher']), size_bytes=len(contents['teacher'])))
        self.assertEqual(len(inputs.saved), 10)
        inputs.recheck()

    def test_packet_duplicate_and_nonfinite_values_fail_before_core_io(self):
        path, packet, _ = packet_files(self.folder)
        valid = json.dumps(packet)
        cases = [
            (valid[:-1] + ', "schema": "private_short_execution_binding_packet_v1"}',
             'Duplicate JSON key'),
            (valid.replace('"path": "prompt.json"',
                           '"path": "prompt.json", "path": "prompt.json"'),
             'Duplicate JSON key'),
        ]
        cases.extend((valid.replace('"private_files": []', '"private_files": [' + number + ']'),
                      'Nonfinite JSON number')
                     for number in ('NaN', 'Infinity', '-Infinity', '1e999'))
        for raw, message in cases:
            with self.subTest(raw=raw):
                path.write_text(raw)
                with patch.object(binding_inputs, 'snapshot', wraps=snapshot) as observed, \
                        self.assertRaisesRegex(ValueError, message):
                    Inputs(path)
                self.assertEqual(observed.call_count, 1, 'invalid packet reached core file IO')

    def test_core_hardlink_collision_rejects_same_bytes_with_valid_pins(self):
        path, _, _ = packet_files(self.folder)
        numeric = self.folder / 'numerical.json'; numeric.unlink()
        os.link(self.folder / 'parent.json', numeric)
        with self.assertRaisesRegex(ValueError, 'distinct files'):
            Inputs(path)

    def test_core_pin_is_not_replaced_by_observed_hash(self):
        path, packet, _ = packet_files(self.folder)
        packet['files']['prompt']['sha256'] = digest(b'[9,9,9]')
        path.write_text(json.dumps(packet))
        with self.assertRaisesRegex(ValueError, 'Raw input pin differs'):
            Inputs(path)

    def test_recheck_detects_same_bytes_new_inode_and_mode_change(self):
        path, _, contents = packet_files(self.folder)
        inputs = Inputs(path)
        replacement = self.folder / 'replacement'; replacement.write_bytes(contents['teacher'])
        replacement.replace(self.folder / 'teacher.json')
        with self.assertRaisesRegex(ValueError, 'changed during audit'):
            inputs.recheck()
        inputs = Inputs(path)
        (self.folder / 'prompt.json').chmod(0o400)
        with self.assertRaisesRegex(ValueError, 'changed during audit'):
            inputs.recheck()

    def test_recheck_rehashes_changed_same_size_bytes(self):
        path, _, _ = packet_files(self.folder)
        inputs = Inputs(path)
        target = self.folder / 'teacher.json'; old = target.stat()
        target.write_bytes(b'[8]')
        os.utime(target, ns=(old.st_atime_ns, old.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, 'changed during audit'):
            inputs.recheck()

    def test_member_map_exact_coverage_and_streamed_recheck(self):
        path, _, _ = packet_files(self.folder); inputs = Inputs(path)
        expected, references = {}, []
        for member, raw in [('Sources/A.swift', b'first'), ('Sources/B.swift', b'second')]:
            file = self.folder / member.rsplit('/', 1)[1]; file.write_bytes(raw)
            expected[member] = dict(path=member, size_bytes=len(raw), sha256=digest(raw))
            references.append(dict(member=member, path=file.name))
        inputs.packet['source_files'] = list(reversed(references))
        self.assertEqual(inputs.members('source', expected), 2)
        inputs.recheck()
        (self.folder / 'A.swift').write_bytes(b'other')
        with self.assertRaisesRegex(ValueError, 'changed during audit'):
            inputs.recheck()

    def test_member_missing_duplicate_unknown_swapped_and_wrong_size_fail(self):
        path, _, _ = packet_files(self.folder)
        expected, references = {}, []
        for name, raw in [('a.py', b'a'), ('b.py', b'bb')]:
            (self.folder / name).write_bytes(raw)
            expected[name] = dict(path=name, size_bytes=len(raw), sha256=digest(raw))
            references.append(dict(member=name, path=name))
        cases = [references[:1], [references[0], references[0]],
                 [references[0], dict(member='other.py', path='b.py')],
                 [dict(member='a.py', path='b.py'), dict(member='b.py', path='a.py')]]
        for refs in cases:
            with self.subTest(references=refs):
                inputs = Inputs(path); inputs.packet['source_files'] = deepcopy(refs)
                with self.assertRaises(ValueError):
                    inputs.members('source', expected)
        inputs = Inputs(path); inputs.packet['source_files'] = references
        bad = deepcopy(expected); bad['a.py']['size_bytes'] = 2
        with self.assertRaisesRegex(ValueError, 'member bytes differ'):
            inputs.members('source', bad)

    def test_member_total_cap_rejects_before_opening_missing_paths(self):
        path, _, _ = packet_files(self.folder)
        for role, size in [('source', 128 * 1024**2 + 1), ('bundle', 2 * 1024**3 + 1)]:
            with self.subTest(role=role):
                inputs = Inputs(path)
                inputs.packet[role + '_files'] = [dict(member='missing', path='does-not-exist')]
                expected = {'missing': dict(path='missing', size_bytes=size, sha256='a' * 64)}
                with self.assertRaisesRegex(ValueError, 'Total retained member bytes'):
                    inputs.members(role, expected)


if __name__ == '__main__':
    unittest.main()
