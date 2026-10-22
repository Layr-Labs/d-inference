"""Prospective CPU controls for the new adapter/join; no native/model/real lease."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE / 'package'))
import gated_reference
from reference_inputs import native_spec, validate_job
from reference_settings import REMOTE, MODEL_DIRECTORY, NATIVE_DIRECTORY, REQUEST_ID, require_short
from reference_resources import validate_local
from validate_collected import EXPECTED, validate


def job():
    source = Path('/Users/developer/DarkbloomDev/cluster-research/registered-full-generation-reference-aligned-payload-supervisor-20260915/example-job.json')
    value = json.loads(source.read_bytes())
    value.update(registered_model='registered_qwen35_9b', request_id=REQUEST_ID, prompt_count=32, chunk_size=16,
        output_count=2, stage_cut=16, stop_token_ids=[], deployment=str(NATIVE_DIRECTORY), model_dir=str(MODEL_DIRECTORY),
        prompt_file=str(REMOTE / 'inputs/prompt.ids.json'), run_dir=str(REMOTE / 'runs/reference-1'))
    return value


class ReferenceBindingTests(unittest.TestCase):
    def test_existing_native_contract_accepts_exact_short_spec(self):
        value = job(); validate_job(value); require_short(value)
        spec = native_spec(value)
        self.assertEqual(spec.argv[0], str(NATIVE_DIRECTORY / 'cluster-inference'))
        fields = dict(zip(spec.argv[1::2], spec.argv[2::2]))
        self.assertEqual(len(fields), 12)
        self.assertEqual([fields[k] for k in ('--prompt-count', '--chunk-size', '--output-count', '--stage-cut', '--stop-token-ids')], ['32', '16', '2', '16', '[]'])
        self.assertNotIn('MLX_RANK', spec.env)

    def test_request_shape_and_namespaces_are_closed(self):
        for key, bad in [('prompt_count', 31), ('chunk_size', 32), ('output_count', 128), ('stage_cut', 4),
                         ('stop_token_ids', [1]), ('request_id', '00000000-0000-0000-0000-000000000001'),
                         ('deployment', '/tmp/unrelated'), ('run_dir', str(REMOTE / 'runs/reference-2'))]:
            value = job(); value[key] = bad
            with self.subTest(key=key), self.assertRaises(ValueError):
                require_short(value)

    def test_changed_native_hash_refuses_before_launch_file(self):
        lease = dict(bytes=0, sha256=hashlib.sha256(b'').hexdigest())
        with patch.object(gated_reference, 'journal', return_value=lease), \
             patch.object(gated_reference, 'processes', return_value={'prohibited': []}), \
             patch.object(gated_reference, 'write_json') as write, \
             patch.object(gated_reference, 'snapshot', return_value={'sha256': '0'*64, 'identity': (1,2,3,4,5,6)}):
            with self.assertRaises(ValueError):
                gated_reference.prepare(job(), REMOTE / 'runs/reference-1')
            self.assertFalse(any(call.args[0].name == 'launch.json' for call in write.call_args_list))

    def test_same_job_cannot_accept_replaced_terminal_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp); (directory / 'terminal.json').write_text('{}\n')
            header = dict(files=[{'path': p} for p in EXPECTED], remoteRoot=str(REMOTE / 'runs/reference-1'), mode='reference', attempt=1)
            with self.assertRaises(ValueError):
                validate(directory, header, {'terminalSHA256': '0'*64}, {}, job())

    def test_extra_or_missing_archive_members_refuse(self):
        for names in (EXPECTED - {'gate.json'}, EXPECTED | {'unrelated.json'}):
            with self.assertRaises(ValueError):
                validate(Path('/no-read'), {'files': [{'path': p} for p in names]}, {}, {}, job())

    def test_normal_pressure_is_required_without_changing_free_floor(self):
        value = dict(actualFreeBytes=6*1024**3, pressureLevel=1, reportedSwapBytes='0', acPower=True,
                     startedMonotonicNS=1, completedMonotonicNS=2)
        validate_local(value)
        for key, bad in [('pressureLevel', 0), ('pressureLevel', 2), ('actualFreeBytes', 6*1024**3-1),
                         ('reportedSwapBytes', '1'), ('acPower', False)]:
            changed = dict(value); changed[key] = bad
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_local(changed)


if __name__ == '__main__':
    unittest.main()
