import json
import os
from pathlib import Path
import tempfile
import unittest

from runtime.stage_checks.common import digest
from planning.measurements.inputs import PacketInputs, stdout_rows


class MeasurementInputTests(unittest.TestCase):
    def packet(self, folder):
        document = dict(schema='cluster_qwen_prefill_measurement_packet_v1', stage_cut=None,
                        provenance={}, files={})
        for name in ('prompt', 'rank0_stdout', 'rank1_stdout', 'rank0_trace', 'rank1_trace'):
            raw = json.dumps(dict(role=name)).encode()
            path = folder / (name + '.json')
            path.write_bytes(raw)
            document['files'][name] = dict(path=path.name, sha256=digest(raw))
        path = folder / 'packet.json'
        path.write_text(json.dumps(document))
        return path, document

    def test_relative_paths_raw_hashes_and_recheck(self):
        with tempfile.TemporaryDirectory() as directory:
            path, _ = self.packet(Path(directory))
            snapshot = PacketInputs(path)
            self.assertEqual(len(snapshot.raw), 5)
            self.assertEqual(snapshot.sha256, digest(path.read_bytes()))
            snapshot.recheck()

    def test_duplicate_paths_and_hard_links_are_rejected(self):
        for hard_link in (False, True):
            with self.subTest(hard_link=hard_link), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                path, doc = self.packet(folder)
                original = folder / doc['files']['rank0_trace']['path']
                alias = folder / 'alias.json'
                if hard_link:
                    os.link(original, alias)
                else:
                    alias = original
                doc['files']['rank1_trace'] = dict(path=alias.name, sha256=digest(original.read_bytes()))
                path.write_text(json.dumps(doc))
                with self.assertRaises(ValueError):
                    PacketInputs(path)

    def test_symlink_and_fifo_do_not_get_read_as_regular_inputs(self):
        for special in ('symlink', 'fifo'):
            with self.subTest(special=special), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                path, doc = self.packet(folder)
                target = folder / 'special'
                if special == 'symlink':
                    target.symlink_to(folder / doc['files']['prompt']['path'])
                else:
                    os.mkfifo(target)
                doc['files']['prompt']['path'] = target.name
                path.write_text(json.dumps(doc))
                with self.assertRaises((OSError, ValueError)):
                    PacketInputs(path)

    def test_wrong_pin_oversized_and_empty_input_are_rejected(self):
        for raw in (b'changed', b'x' * 65537, b''):
            with self.subTest(size=len(raw)), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                path, doc = self.packet(folder)
                (folder / doc['files']['prompt']['path']).write_bytes(raw)
                with self.assertRaises(ValueError):
                    PacketInputs(path)

    def test_input_or_packet_changes_fail_postflight(self):
        for which in ('input', 'packet'):
            with self.subTest(which=which), tempfile.TemporaryDirectory() as directory:
                folder = Path(directory)
                path, doc = self.packet(folder)
                snapshot = PacketInputs(path)
                target = path if which == 'packet' else folder / doc['files']['prompt']['path']
                target.write_bytes(target.read_bytes() + b' ')
                with self.assertRaises(ValueError):
                    snapshot.recheck()

    def test_duplicate_packet_keys_and_unknown_reference_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path, doc = self.packet(Path(directory))
            doc['files']['prompt']['unexpected'] = True
            path.write_text(json.dumps(doc))
            with self.assertRaises(ValueError):
                PacketInputs(path)
            path.write_bytes(b'{"schema":1,"schema":2}')
            with self.assertRaises(ValueError):
                PacketInputs(path)

    def test_jsonl_has_exactly_two_strict_records(self):
        self.assertEqual(stdout_rows(b'{"a":1}\n{"b":2}\n'), [{'a': 1}, {'b': 2}])
        for raw in (b'{}\n', b'{}\n{}', b'{}\r{}\r', b'{}\n\n{}\n', b'{}\n{}\n{}',
                    b'{"a":1,"a":2}\n{}\n', b'{"x":NaN}\n{}\n'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                stdout_rows(raw)


if __name__ == '__main__':
    unittest.main()
