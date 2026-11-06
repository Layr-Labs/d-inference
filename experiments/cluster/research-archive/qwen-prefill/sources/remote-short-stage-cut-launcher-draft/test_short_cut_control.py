"""Pinned control and provenance mutations with only temporary fabricated files."""
from contextlib import ExitStack
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import long_reference_inputs as source
from long_reference_configuration import configuration
from short_cut_test_fixture import (RAW_PROMPT, RAW_TEACHER, RAW_PREFIX, RAW_TEXT, ORIGIN,
                                   PROMPT_SHA, TEACHER_SHA, sha)


class Tests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.path = Path(temp.name)
        for name in ('subprocess.run', 'subprocess.Popen', 'socket.socket'):
            guard = patch(name, side_effect=AssertionError('Real process/socket forbidden'))
            guard.start(); self.addCleanup(guard.stop)

    def test_named_origin_source_and_history_mutations_rejected_even_with_matching_raw_pin(self):
        mutations = [lambda o: o['native_calls'][0].update(name='ordinary-native'),
                     lambda o: o['native_calls'].append(dict(o['native_calls'][0])),
                     lambda o: o['native_calls'][0].update(exit_code=True),
                     lambda o: o['native_calls'][0].update(status='failed'),
                     lambda o: o['native_calls'][0]['rank_evidence_sha256'].update({'rank-0/teacher.json': 'f' * 64}),
                     lambda o: o.update(baseline_teacher_tokens=[1, 2, 3]),
                     lambda o: o['tokenization'].update(source_text_sha256='f' * 64),
                     lambda o: o['tokenization'].update(prompt_ids=[3] * 96)]
        for index, mutate in enumerate(mutations):
            directory = self.path / str(index); directory.mkdir()
            origin = json.loads(json.dumps(ORIGIN)); mutate(origin); raw_origin = json.dumps(origin).encode()
            for name, raw in [('prompt', RAW_PROMPT), ('teacher', RAW_TEACHER), ('prefix', RAW_PREFIX),
                              ('text', RAW_TEXT), ('origin', raw_origin)]: (directory / name).write_bytes(raw)
            with patch.multiple(source, PROMPT_SHA256=PROMPT_SHA, TEACHER_SHA256=TEACHER_SHA,
                ORIGIN_SHA256=sha(raw_origin), PREFIX96_SHA256=sha(RAW_PREFIX), SOURCE_TEXT_SHA256=sha(RAW_TEXT)):
                with self.assertRaises(ValueError):
                    source.archive_inputs(directory / 'prompt', PROMPT_SHA, directory / 'teacher', TEACHER_SHA,
                        directory / 'origin', sha(raw_origin), directory / 'prefix', directory / 'text', directory)
            self.assertFalse((directory / 'inputs').exists())

    def test_remote_before_after_verify_and_seal_both_actual_owned_raw_files(self):
        native = self.path / 'native'; native.mkdir()
        bundle = native / 'bundle'; bundle.mkdir()
        model = self.path / 'fabricated-model-metadata'; model.mkdir()
        (self.path / 'metadata').mkdir()
        (bundle / 'cluster-inference').write_bytes(b'not executable')
        (bundle / 'bundle.json').write_text(json.dumps({'files': []}))
        (model / 'config.json').write_bytes(b'{}'); (model / 'manifest.json').write_bytes(b'{}')
        (native / 'prompt.json').write_bytes(RAW_PROMPT); (native / 'teacher.json').write_bytes(RAW_TEACHER)
        digest = lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
        rank = configuration(str(bundle), digest(bundle / 'bundle.json'), str(model), PROMPT_SHA, TEACHER_SHA)
        (native / 'rank.json').write_text(json.dumps(rank))
        config = dict(run=str(self.path), native=str(native), bundle=str(bundle), model=str(model),
            bundle_sha256=digest(bundle / 'bundle.json'), binary_sha256=digest(bundle / 'cluster-inference'),
            rank_sha256=digest(native / 'rank.json'), prompt_size_bytes=len(RAW_PROMPT), prompt_sha256=PROMPT_SHA,
            teacher_size_bytes=len(RAW_TEACHER), teacher_sha256=TEACHER_SHA,
            required_environment=rank['environment'], configuration_sha256=digest(model / 'config.json'), artifact_sha256='a' * 64)
        model_calls = []
        fake = SimpleNamespace(file_sha256=digest,
            verify_files=lambda *args: {'cluster-inference': config['binary_sha256']},
            verify_model=lambda *args: model_calls.append(args) or 'a' * 64)
        with patch.dict(sys.modules, {'artifacts': fake}):
            spec = importlib.util.spec_from_file_location('short_control_under_test', Path(__file__).with_name('remote_prefill_control.py'))
            control = importlib.util.module_from_spec(spec); spec.loader.exec_module(control)
        with patch.object(control, 'observation', return_value={'fake': True}), \
             patch.object(control, 'resource_preflight', return_value={'passed': True}):
            before = control.verify_and_record(config, 'before')
            after = control.verify_and_record(config, 'after')
            for record in (before, after):
                self.assertEqual(record['prompt_sha256'], PROMPT_SHA)
                self.assertEqual(record['teacher_sha256'], TEACHER_SHA)
                self.assertFalse(record['raw_prompt_reencoded']); self.assertFalse(record['raw_teacher_reencoded'])
            self.assertEqual((native / 'teacher.json').stat().st_mode & 0o777, 0o400)
            self.assertEqual((native / 'prompt.json').stat().st_mode & 0o777, 0o400)
            self.assertEqual(len(model_calls), 2)
            (native / 'teacher.json').chmod(0o600); (native / 'teacher.json').write_bytes(b'[1,2,3]')
            with self.assertRaisesRegex(ValueError, 'raw teacher'):
                control.verify_and_record(config, 'after')
            self.assertEqual(len(model_calls), 2)


if __name__ == '__main__': unittest.main()
