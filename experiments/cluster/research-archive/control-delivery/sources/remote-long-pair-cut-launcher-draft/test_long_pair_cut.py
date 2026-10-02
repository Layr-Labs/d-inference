"""Invented metadata and fake processes only; no candidate or natural input reads."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from long_pair_cut import selection_receipt
from long_reference_configuration import configuration, require_rank_configuration, timeout
from long_reference_contract import validate_first, validate_final
from long_reference_inputs import archive_inputs, parse_prompt
from long_reference_test_fixture import Child
from remote_prefill_paths import paths
from remote_prefill_supervision import supervise
from test_long_pair_outer_contract import fixture


def legacy_configuration():
    path = Path(__file__).parent / 'originals/long_reference_configuration.py'
    spec = importlib.util.spec_from_file_location('cut_pair_original_configuration', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.configuration


class CutTests(unittest.TestCase):
    def test_only_native_argv_delta_is_one_cut_pair(self):
        original = legacy_configuration()('/bundle', 'c'*64, '/model', 'a'*64)
        actual = configuration('/bundle', 'c'*64, '/model', 'a'*64)
        index = actual['arguments'].index('--stage-cut')
        self.assertEqual(actual['arguments'].count('--stage-cut'), 1)
        self.assertEqual(actual['arguments'][index:index+2], ['--stage-cut', '12'])
        del actual['arguments'][index:index+2]
        self.assertEqual(actual, original)

    def test_missing_duplicate_and_wrong_cut_are_rejected(self):
        original = configuration('/bundle', 'c'*64, '/model', 'a'*64)
        index = original['arguments'].index('--stage-cut')
        for replacement in ([], ['--stage-cut','16'], ['--stage-cut','0'],
                            ['--stage-cut','12','--stage-cut','12']):
            changed = copy.deepcopy(original)
            changed['arguments'][index:index+2] = replacement
            with self.assertRaises(ValueError):
                require_rank_configuration(changed, '/bundle', 'c'*64, '/model', 'a'*64)

    def test_selected_receipt_is_distinct_and_unqualified(self):
        a, b = selection_receipt(), selection_receipt()
        self.assertEqual(a['stage_cut'], 12)
        self.assertEqual(a['source_layer_ranges'], [[0,12],[12,32]])
        self.assertIs(a['independent_numerical_comparison_run'], False)
        a['source_layer_ranges'][0][1] = 16
        self.assertEqual(b['source_layer_ranges'][0][1], 12)

    def test_half_reference_cannot_be_mixed_with_selected_stages(self):
        inputs, first, _ = fixture()
        first['reference']['execution']['source']['planSHA256'] = 'e'*64
        with self.assertRaises(ValueError): validate_first(first, inputs)

    def test_reference_full_source_bounds_are_exact(self):
        inputs, first, _ = fixture()
        for key, value in [('layerCount',32.0), ('layerCount',12),
                           ('sourceModelTensorBytes',5038041600.0), ('sourceParameterLayoutSHA256','e'*64)]:
            changed = copy.deepcopy(first); changed['reference']['execution']['source'][key] = value
            with self.assertRaises(ValueError): validate_first(changed, inputs)

    def test_stale_stage_plan_or_local_configuration_is_rejected(self):
        inputs, first, final = fixture()
        for rank in (0,1):
            for key in ('planSHA256','stagePlanSHA256','constructionConfigurationSHA256',
                        'sourceParameterLayoutSHA256'):
                changed=copy.deepcopy(final);changed['stageLoads'][rank][key]='e'*64
                with self.assertRaises(ValueError): validate_final(changed, first, inputs)

    def test_stage_index_must_be_integer_not_boolean(self):
        inputs, first, final = fixture()
        final['stageLoads'][0]['stageIndex'] = False
        with self.assertRaises(ValueError): validate_final(final, first, inputs)

    def test_agreement_must_bind_both_selected_stage_roles(self):
        inputs, first, final = fixture()
        for key in final['comparison']['agreement']:
            changed=copy.deepcopy(final);changed['comparison']['agreement'][key]='e'*64
            with self.assertRaises(ValueError): validate_final(changed, first, inputs)

    def test_stages_must_share_observed_storage_with_agreement(self):
        inputs, first, final = fixture()
        final['stageLoads'][1]['storageCommitmentSHA256'] = 'e'*64
        with self.assertRaises(ValueError): validate_final(final, first, inputs)

    def test_actual_solo_path_constructor_drives_worker_bundle(self):
        layout=paths('/home/owner', '/runs', '/models/pinned', 'a'*32)
        self.assertEqual(layout['native'], layout['run']+'/native')
        self.assertEqual(layout['bundle'], layout['native']+'/bundle')
        config=configuration(layout['bundle'], 'c'*64, layout['model'], 'a'*64)
        self.assertEqual(config['bundle'], layout['run']+'/native/bundle')
        wrong=dict(config,bundle=layout['run']+'/bundle')
        with self.assertRaises(ValueError):
            require_rank_configuration(wrong,layout['bundle'],'c'*64,layout['model'],'a'*64)

    def test_bounded_parent_policy_is_unchanged(self):
        for value in (1,300,330):timeout(value)
        for value in (True,0,-1,331,330.0):
            with self.assertRaises(ValueError):timeout(value)

    def test_raw_prompt_and_opaque_origin_are_not_reserialized(self):
        raw=('[ '+', '.join(['3']*8192)+' ]\n').encode();origin=b'{"invented":true}\n'
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);prompt=root/'prompt';proof=root/'origin';output=root/'output';output.mkdir()
            prompt.write_bytes(raw);proof.write_bytes(origin)
            result=archive_inputs(prompt,hashlib.sha256(raw).hexdigest(),proof,hashlib.sha256(origin).hexdigest(),output)
            self.assertEqual((output/'inputs/prompt.json').read_bytes(),raw)
            self.assertEqual((output/'inputs/prompt-origin.json').read_bytes(),origin)
            self.assertIs(result['raw_prompt_reencoded'],False)
            self.assertEqual(result['teacher'],[])
            with self.assertRaises(ValueError):
                archive_inputs(prompt,'e'*64,proof,hashlib.sha256(origin).hexdigest(),root/'unused')

    def test_prompt_geometry_and_integer_spelling_remain_closed(self):
        for bad in ([3]*8191, [3]*8193, [True]+[3]*8191, [3.0]+[3]*8191):
            with self.assertRaises(ValueError):parse_prompt(json.dumps(bad).encode())

    def test_expiry_during_memory_observation_fails_before_success(self):
        class Reader:
            def __init__(self,*_):self.rows=[{},{}]
            def poll(self,final=False):pass
        now=[0.0];child=Child(0);stops=[]
        def memory(_):now[0]=331.0
        with patch('remote_prefill_supervision.Records',Reader):
            result=supervise({'local':'/unused'}, {},330,lambda _:child,
                lambda ranks,children:stops.append((ranks,children)),memory,clock=lambda:now[0],sleep=lambda _:None)
        self.assertIs(result['passed'],False)
        self.assertEqual(result['cancellation_reason'],'local_parent_deadline')
        self.assertEqual(len(stops),1)
        self.assertEqual(child.waits,1)
        self.assertIs(result['remote_process_reaping_independently_verified'],False)

    def test_primary_and_cleanup_failures_are_both_preserved(self):
        class Reader:
            def __init__(self,*_):self.rows=[]
            def poll(self,final=False):raise ValueError('invented primary failure')
        child=Child(0)
        def stop(*_):raise RuntimeError('invented cleanup failure')
        with patch('remote_prefill_supervision.Records',Reader):
            result=supervise({'local':'/unused'}, {},330,lambda _:child,stop,lambda _:None,clock=lambda:0,sleep=lambda _:None)
        self.assertIs(result['passed'],False)
        self.assertIn('invented primary failure',result['error'])
        self.assertIn('invented cleanup failure',result['cleanup_errors'][0]['error'])


if __name__ == '__main__':
    with patch('subprocess.Popen',side_effect=AssertionError('No processes in CPU tests')), \
         patch('socket.socket',side_effect=AssertionError('No sockets in CPU tests')):
        unittest.main()
