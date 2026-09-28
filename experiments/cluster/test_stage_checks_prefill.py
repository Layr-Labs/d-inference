"""Pure/fake v3 option, baseline, agreement and initial-memory regressions."""
import copy
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stderr
from runtime.stage_checks import cli,configuration,prefill,prefill_baseline
from runtime.stage_checks.common import canonical,digest
from runtime.stage_checks.prefill_resources import initial_free_screen
from runtime.stage_checks.stream import Records
from stage_prefill_test_support import EPOCH,baseline,context,rows


class PrefillTests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard=patch(target,side_effect=AssertionError('No process/socket calls'));guard.start();self.addCleanup(guard.stop)
        self.ctx=context()

    def arguments(self):
        return ['prefill-ranks','--release','/release','--runtime','/runtime','--output','/new-output',
            '--expected-binary-sha256','a'*64,'--model-dir','/model','--artifact-aggregate-sha256','b'*64,
            '--tokens-file','/tokens.json','--stage-prefill-policy','serial_v1','--stage-logits-dtype','bfloat16',
            '--baseline-jsonl','/baseline.jsonl','--baseline-sha256','c'*64,'--baseline-evidence-sha256','d'*64]

    def test_explicit_policy_dtype_and_both_baseline_pins_required(self):
        args=self.arguments();parsed=cli.parser().parse_args(args)
        self.assertEqual(parsed.chunk_size,32);self.assertIsNone(parsed.teacher_tokens_file)
        for name in ('--stage-prefill-policy','--stage-logits-dtype','--baseline-jsonl','--baseline-sha256','--baseline-evidence-sha256'):
            changed=args[:];index=changed.index(name);del changed[index:index+2]
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):cli.parser().parse_args(changed)

    def test_prefill_does_not_expose_larger_schedule_remote_or_worker_flags(self):
        for extra in (['--chunk-size','16'],['--teacher-tokens-file','x'],['--host','host'],['--repeats','2'],
                      ['--stage-prefill-policy','other'],['--stage-logits-dtype','uint32']):
            with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):cli.parser().parse_args(self.arguments()+extra)

    def test_argv_binds_each_policy_dtype_and_no_teacher(self):
        for policy in prefill.POLICIES:
            for dtype in ('float16','bfloat16','float32'):
                ctx=context(policy,dtype)
                cfg=configuration.build(1,EPOCH,ctx,'/bundle','a'*64,[['127.0.0.1:20001'],['127.0.0.1:20002']],180)
                args=dict(zip(cfg['arguments'][::2],cfg['arguments'][1::2]))
                self.assertEqual(args['--mode'],'qwen-layer-stage-prefill-rank-check')
                self.assertEqual(args['--stage-prefill-policy'],policy);self.assertEqual(args['--stage-logits-dtype'],dtype)
                self.assertEqual([args[x] for x in ('--prompt-tokens','--chunk-size','--decode-tokens')],['65','32','1'])
                self.assertNotIn('--teacher-tokens-file',args);self.assertEqual(cfg['environment']['MLX_RANK'],'1')

    def test_wrong_fixed_count_or_unbound_dtype_refused(self):
        for field,value in [('promptCount',64),('chunkSize',16),('outputCount',2)]:
            ctx=copy.deepcopy(self.ctx);ctx['request']['request'][field]=value
            with self.assertRaises(ValueError):configuration.build(0,EPOCH,ctx,'/b','a'*64,[['127.0.0.1:2'],['127.0.0.1:3']],180)
        ctx=copy.deepcopy(self.ctx);ctx['baseline_admission']['logits_dtype']='float32'
        with self.assertRaises(ValueError):configuration.build(0,EPOCH,ctx,'/b','a'*64,[['127.0.0.1:2'],['127.0.0.1:3']],180)

    def test_all_three_baseline_dtypes_admit_metadata_without_candidate_comparison(self):
        for dtype in ('float16','bfloat16','float32'):
            ctx=context(dtype=dtype);_,raw,pin=baseline(ctx)
            value=prefill_baseline.admit(raw,ctx,pin,dtype)
            self.assertEqual(value['evidence_sha256'],pin);self.assertEqual(value['final_frontier'],65)
            self.assertFalse(value['candidate_numerical_comparison_performed'])

    def test_baseline_raw_and_native_fingerprint_pins_are_independent(self):
        _,raw,pin=baseline(self.ctx)
        for bad_raw,bad_pin in [(raw+b' ',pin),(raw,'0'*64)]:
            with self.assertRaises(ValueError):prefill_baseline.admit(bad_raw,self.ctx,bad_pin,'bfloat16')

    def test_wrong_final_dtype_even_valid_file_pin_rejected(self):
        _,raw,pin=baseline(self.ctx)
        with self.assertRaises(ValueError):prefill_baseline.admit(raw,self.ctx,pin,'float32')

    def test_baseline_rejects_source_history_retirement_and_state_changes(self):
        original,_,pin=baseline(self.ctx)
        for mutate in (lambda b:b['source'].__setitem__('artifactAggregateSHA256','0'*64),
                       lambda b:b['request']['promptTokenIDs'].__setitem__(0,7),
                       lambda b:b.__setitem__('allRequestStateRetired',False),
                       lambda b:b['frames'][0]['state'].__setitem__('fingerprint','0'*64),
                       lambda b:b['frames'][-1]['logits']['values'].__setitem__(0,1)):
            row=copy.deepcopy(original);mutate(row['baseline']);raw=canonical(row)+b'\n';self.ctx['baseline_sha256']=digest(raw)
            with self.assertRaises(ValueError):prefill_baseline.admit(raw,self.ctx,pin,'bfloat16')

    def test_missing_or_duplicate_checkpoint_is_not_admitted(self):
        row,raw,pin=baseline(self.ctx)
        for value in (canonical({'kind':'other'})+b'\n',raw+raw):
            self.ctx['baseline_sha256']=digest(value)
            with self.assertRaises(ValueError):prefill_baseline.admit(value,self.ctx,pin,'bfloat16')

    def test_opaque_execution_does_not_become_numeric_or_timing_pass(self):
        finals=[]
        for rank in (0,1):
            ready,final=rows(rank,self.ctx)
            prefill.validate(ready,rank,EPOCH,self.ctx);prefill.validate(final,rank,EPOCH,self.ctx)
            prefill.transition(ready,final,self.ctx);finals.append(final)
        result=prefill.pair(finals,self.ctx)
        self.assertTrue(result['outer_identity_and_completion_validated'])
        self.assertFalse(result['numerical_audit_performed']);self.assertFalse(result['throughput_qualification'])

    def test_closed_agreement_rejects_changed_policy_bool_count_dtype_extra_or_hash(self):
        original=rows(0,self.ctx)[0]
        for key,value in [('schedulingPolicy','prompt_lookahead_one_v1'),('frameCount',True),('nativeDType','float32'),
                          ('logitsDType','float32'),('unknown',1),('planFingerprint','0'*64)]:
            row=copy.deepcopy(original);row['agreement'][key]=value
            row['agreementFingerprint']=digest(b'qwen-prefill-start-agreement-v1\n'+canonical(row['agreement']))
            with self.assertRaises(ValueError):prefill.validate(row,0,EPOCH,self.ctx)
        row=copy.deepcopy(original);row['agreementFingerprint']='0'*64
        with self.assertRaises(ValueError):prefill.validate(row,0,EPOCH,self.ctx)

    def test_terminal_claims_source_and_frontier_rejected(self):
        for mutate in (lambda r:r.__setitem__('throughputMeasurementValid',True),lambda r:r.__setitem__('modelReleased',False),
                       lambda r:r['sourceLoad'].__setitem__('stageIndex',1),lambda r:r['request']['request'].__setitem__('outputCount',2),
                       lambda r:r.__setitem__('execution',{})):
            row=rows(0,self.ctx)[1];mutate(row)
            with self.assertRaises(ValueError):prefill.validate(row,0,EPOCH,self.ctx)

    def test_stream_rejects_ready_final_change_in_valid_stage_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            values=rows(0,self.ctx);values[1]['agreement']=copy.deepcopy(values[1]['agreement'])
            values[1]['agreement']['consumerStageFingerprint']='0'*64
            values[1]['agreementFingerprint']=digest(b'qwen-prefill-start-agreement-v1\n'+canonical(values[1]['agreement']))
            path=Path(temporary);(path/'stdout.jsonl').write_bytes(b''.join(canonical(v)+b'\n' for v in values))
            with self.assertRaisesRegex(ValueError,'Ready/final'):Records(path,0,EPOCH,self.ctx,prefill).poll(final=True)

    def test_initial_free_is_before_hash_screen_not_reclaimable_or_launch_guarantee(self):
        def raw(free):return f'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: {free}.\nPages inactive: 999999.\nPages speculative: 10.\n'
        limit=6*1024**3//16384
        self.assertFalse(initial_free_screen(lambda:raw(limit-1))['passed'])
        record=initial_free_screen(lambda:raw(limit));self.assertTrue(record['passed'])
        self.assertFalse(record['guarantees_six_gib_free_at_native_launch'])
        self.assertEqual(record['actual_free_bytes'],6*1024**3)


if __name__=='__main__':unittest.main()
