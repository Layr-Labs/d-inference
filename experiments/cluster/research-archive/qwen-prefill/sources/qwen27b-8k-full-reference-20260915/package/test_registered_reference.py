"""Registered request/source/coverage fixtures, including two real CPU children."""
import copy
import hashlib
import json
from pathlib import Path
import unittest

from binding_common import canonical
from fabricated_reference import records
from reference_contract import admitted, expected_identity, report
from reference_inputs import native_spec, validate_job
from reference_profiles import registered_profile
from reference_state import expected_entries
import test_reference_supervisor as inherited
from test_reference_supervisor import job_at

MODELS = ('registered_qwen35_9b', 'registered_qwen38_27b')


class RegisteredChecks(unittest.TestCase):
    def fixture(self, model, prompt=32, chunk=16, output=128, stops=None, actual=None, reason='length'):
        job = job_at(Path('/invented'), model=model, prompt_count=prompt, chunk_size=chunk,
                     output_count=output, stop_token_ids=stops)
        ids = [17] * prompt
        first, last = records(job, ids, 123, actual_count=actual, finish_reason=reason)
        return job, expected_identity(job, ids), first, last

    def check(self, job, expected, first, last):
        admitted(canonical(first), expected)
        return report(canonical(last), expected, first, 123, Path(job['deployment']))

    def test_both_registered_models_and_source_vectors(self):
        for model, tensors, size, entries, state_bytes in [
            (MODELS[0], 927, 5038041600, 72, 56721440),
            (MODELS[1], 1847, 15132802048, 144, 164364352),
        ]:
            job, expected, first, last = self.fixture(model)
            self.check(job, expected, first, last)
            self.assertEqual(expected.model.tensor_count, tensors)
            self.assertEqual(expected.model.source_bytes, size)
            values = expected_entries(expected.model, 159)
            self.assertEqual(len(values), entries)
            self.assertEqual(sum(x['byteCount'] for x in values), state_bytes)

    def test_short_partial_and_maximum_request_geometry(self):
        for model in MODELS:
            for prompt, chunk, output in [(1, 512, 1), (31, 16, 2), (513, 512, 128), (8192, 1, 128)]:
                job, expected, first, last = self.fixture(model, prompt, chunk, output)
                validate_job(job); self.check(job, expected, first, last)
                self.assertEqual(last['execution']['committedTokens'], prompt + output - 1)
                self.assertEqual(last['execution']['completedFrames'], (prompt-1)//chunk + output)
                argv = native_spec(job).argv
                self.assertEqual(len(argv), 25)
                flags = dict(zip(argv[1::2], argv[2::2]))
                self.assertEqual(flags['--mode'], 'qwen-registered-full-generation-reference')
                self.assertEqual(flags['--registered-dense-profile'], model)
                self.assertEqual(flags['--prompt-count'], str(prompt))
                self.assertEqual(flags['--chunk-size'], str(chunk))
                self.assertEqual(flags['--output-count'], str(output))

    def test_closed_model_cut_and_integer_bounds(self):
        for model in MODELS:
            job, _, _, _ = self.fixture(model)
            for cut in registered_profile(model).cuts:
                validate_job(dict(job, stage_cut=cut))
            for key, value in [('registered_model', 'other'), ('prompt_count', 0), ('prompt_count', 8193),
                    ('prompt_count', True), ('chunk_size', 0), ('chunk_size', 513), ('chunk_size', 1.0),
                    ('output_count', 0), ('output_count', 129), ('stop_token_ids', [2, 1]),
                    ('stop_token_ids', [1, 1]), ('stop_token_ids', [False]), ('stop_token_ids', [248320]),
                    ('stop_token_ids', list(range(257))), ('stage_cut', 20)]:
                with self.subTest(model=model, key=key, value=value), self.assertRaises(ValueError):
                    validate_job(dict(job, **{key:value}))
        with self.assertRaises(ValueError): validate_job(dict(job_at(Path('/invented')), stage_cut=32))

    def test_eos_uses_actual_output_frontier_and_preserves_capacity(self):
        for model in MODELS:
            for actual in (1, 2, 128):
                job, expected, first, last = self.fixture(model, stops=[17], actual=actual, reason='eos')
                self.check(job, expected, first, last)
                self.assertEqual(last['execution']['maximumTokens'], 160)
                self.assertEqual(last['execution']['committedTokens'], 32 + actual - 1)
            for mutate in [
                lambda x: x.update(finishReason='length'),
                lambda x: x.update(finishReason='clientStop'),
                lambda x: x.update(committedTokens=159),
                lambda x: x.update(completedFrames=129),
                lambda x: x['selectedTokenIDs'].__setitem__(-1, 18),
                lambda x: x['selectedTokenIDs'].__setitem__(0, 17),
            ]:
                job, expected, first, last = self.fixture(model, stops=[17], actual=2, reason='eos')
                mutate(last['execution'])
                with self.assertRaises(ValueError): self.check(job, expected, first, last)

    def test_full_state_missing_duplicate_mapping_shape_dtype_digest(self):
        for model in MODELS:
            for mutate in [
                lambda x: x['entries'].pop(),
                lambda x: x['entries'].__setitem__(1, copy.deepcopy(x['entries'][0])),
                lambda x: x['entries'][0].update(globalLayerIndex=99),
                lambda x: x['entries'][0].update(dtype='float16'),
                lambda x: x['entries'][0].update(shape=[1, 3, 1]),
                lambda x: x['entries'][0].update(byteCount=1),
                lambda x: x['entries'][0].update(sha256='0'*64),
                lambda x: x.update(logicalByteCount=1),
                lambda x: x.update(committedTokens=158),
            ]:
                job, expected, first, last = self.fixture(model)
                mutate(last['execution']['finalState'])
                with self.assertRaises(ValueError): self.check(job, expected, first, last)

    def test_source_request_token_row_substitution(self):
        job, expected, first, last = self.fixture(MODELS[1])
        wrong = copy.deepcopy(first); wrong['configurationSHA256'] = registered_profile(MODELS[0]).configuration
        with self.assertRaises(ValueError): admitted(canonical(wrong), expected)
        for mutate in [
            lambda x: x['source'].update(layerCount=32),
            lambda x: x['sourceLoad'].update(tensorCount=927),
            lambda x: x['tokens'][0]['frame'].update(tokenCount=32),
            lambda x: x['tokens'][0].update(logitsShape=[1, 1]),
            lambda x: x['tokens'][0].update(tokenID=True),
            lambda x: x['finalLogits'].update(logicalBytesSHA256='0'*64),
            lambda x: x['finalLogits']['values'].__setitem__(0, True),
            lambda x: x.update(stopTokenIDs=[17]),
            lambda x: x.update(chunkSize=512),
        ]:
            wrong = copy.deepcopy(last); mutate(wrong['execution'])
            with self.assertRaises(ValueError): self.check(job, expected, first, wrong)

    def test_pinned_upcoming_packet(self):
        here = Path(__file__).parent / 'request-input'
        packet = json.loads((here/'request.json').read_text())
        raw = (here/'prompt.ids.json').read_bytes(); ids = json.loads(raw)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), '6d4c8898c3d6f01ddd8c3e712cde5005c647db64937977dd907935146442e81e')
        self.assertEqual(hashlib.sha256(','.join(map(str,ids)).encode()).hexdigest(), packet['promptTokenIDsSHA256'])
        self.assertEqual((len(ids),packet['chunkSize'],packet['outputCount'],packet['stageCut']), (32,16,128,32))
        self.assertEqual(packet['requestID'], '20801ced-ca29-4faf-b71a-9ebbe1886a14')
        profile = registered_profile(packet['model'])
        self.assertEqual((packet['artifactSHA256'],packet['configurationSHA256'],packet['manifestSHA256']),
                         (profile.artifact,profile.configuration,profile.manifest))

    def test_actual_registered_python_children_complete_and_eos(self):
        helper = inherited.Checks()
        for case, changes in [('good', {}), ('early-eos', {'stop_token_ids':[17]})]:
            code, receipt = helper.child(case, job_changes=dict(model=MODELS[1], prompt_count=32, chunk_size=16, **changes))
            self.assertEqual(code, 0)
            self.assertEqual(receipt['nativeExitCodes'], [0])
            self.assertTrue(receipt['outputComplete'])


if __name__ == '__main__': unittest.main()
