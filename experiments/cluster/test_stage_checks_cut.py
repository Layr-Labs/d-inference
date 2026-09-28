"""Explicit short-rank cut CPU checks; processes/sockets and actual inputs forbidden."""
import argparse
import copy
from contextlib import redirect_stderr
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from runtime.stage_checks import baseline,cli,configuration,evidence,inputs,ranks,stage_ranges,storage
from runtime.stage_checks.common import canonical,digest
from stage_cut_test_support import EPOCH,context,loads,reports,states,baseline as baseline_fixture

HOSTS=[['127.0.0.1:20001'],['127.0.0.1:20002']]


class StageCutTests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard=patch(target,side_effect=AssertionError('No actual process/socket calls'));guard.start();self.addCleanup(guard.stop)
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup);self.path=Path(temporary.name)

    def args(self,mode='ranks'):
        result=[mode,'--release','/unused-release','--runtime','/unused-runtime','--output','/new-output','--expected-binary-sha256','a'*64]
        if mode!='p2p':result+=['--model-dir','/unused-model','--artifact-aggregate-sha256','b'*64,'--tokens-file','/unused-tokens']
        if mode=='prefill-ranks':result+=['--stage-prefill-policy','serial_v1','--stage-logits-dtype','bfloat16',
            '--baseline-jsonl','/unused-baseline','--baseline-sha256','c'*64,'--baseline-evidence-sha256','d'*64]
        if mode.startswith('long-'):
            result+=['--tokens-sha256','c'*64,'--prompt-origin-file','/unused-origin','--prompt-origin-sha256','d'*64]
            if mode.endswith('ranks'):result+=['--stage-prefill-policy','serial_v1','--stage-logits-dtype','bfloat16']
        return result

    def test_parser_short_and_long_stage_cut_scopes_and_no_duplicate(self):
        self.assertEqual(cli.parser().parse_args(self.args()+['--stage-cut','12']).stage_cut,12)
        self.assertIsNone(cli.parser().parse_args(self.args()).stage_cut)
        for mode in ('p2p','prefill-ranks','long-prefill-ranks','long-prefill-solo'):
            self.assertEqual(cli.parser().parse_args(self.args(mode)).command,mode)
        for args in [self.args()+['--stage-cut','12','--stage-cut','16']]+[self.args(m)+['--stage-cut','12'] for m in ('p2p','prefill-ranks','long-prefill-solo')]:
            with self.subTest(args=args),redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):cli.parser().parse_args(args)

    def test_explicit_unequal_and_odd_nonhalf_geometry(self):
        for layers,cut,wanted in [(32,12,((0,12),(12,32))),(12,4,((0,4),(4,12))),
            (11,4,((0,4),(4,11))),(13,8,((0,8),(8,13)))]:
            self.assertEqual(stage_ranges.ranges(context(layers,cut)['text'],cut),wanted)
        for layers in (11,12,13):
            with self.assertRaises(ValueError):stage_ranges.ranges(context(layers)['text'])

    def test_strict_cut_and_interval_boundaries(self):
        for value in (True,False,12.0,'12',0,-1,128,32,31,2,14,29):
            with self.subTest(value=value),self.assertRaises(ValueError):stage_ranges.ranges(context()['text'],value)
        for layers,interval,cut in [(129,4,12),(1,4,1),(8,1,4),(8,0,4),(8,129,4),(7,4,4),(9,4,8)]:
            text=dict(num_hidden_layers=layers,full_attention_interval=interval)
            with self.assertRaises(ValueError):stage_ranges.ranges(text,cut)
        for mode in ('p2p','prefill-ranks','long-prefill-ranks','long-prefill-solo'):
            with self.assertRaises(ValueError):stage_ranges.option(mode,12)

    def test_omission_and_explicit_half_keep_request_and_existing_argv(self):
        old=context();chosen=context(cut=16)
        self.assertEqual(old['request'],chosen['request']);self.assertEqual(old['request_fingerprint'],chosen['request_fingerprint'])
        self.assertEqual(stage_ranges.for_context(old),stage_ranges.for_context(chosen))
        a=configuration.build(0,EPOCH,old,'/b','c'*64,HOSTS,180)
        b=configuration.build(0,EPOCH,chosen,'/b','c'*64,HOSTS,180)
        self.assertNotIn('--stage-cut',a['arguments']);position=b['arguments'].index('--stage-cut')
        self.assertEqual(b['arguments'][position:position+2],['--stage-cut','16'])
        del b['arguments'][position:position+2];self.assertEqual(a,b)

    def test_configuration_and_prepare_refuse_foreign_or_invalid_cut_before_io(self):
        for mode in ('p2p','prefill-ranks','long-prefill-ranks','long-prefill-solo'):
            ctx=dict(mode=mode,stage_cut=12)
            with self.assertRaises(ValueError):configuration.build(0,EPOCH,ctx,'/b','c'*64,HOSTS,180)
            with patch.object(Path,'open',side_effect=AssertionError('No input IO')):
                with self.assertRaises(ValueError):inputs.prepare(argparse.Namespace(command=mode,stage_cut=12),self.path,EPOCH,Mock())
        for cut in (0,True,128):
            with self.assertRaises(ValueError):configuration.build(0,EPOCH,context(cut=cut),'/b','c'*64,HOSTS,180)

    def retained(self,layers,cut):
        ctx=context(layers,cut);model=self.path/f'model-{layers}-{cut}';model.mkdir();output=self.path/f'output-{layers}-{cut}';output.mkdir()
        raw=canonical(ctx['configuration']);(model/'config.json').write_bytes(raw)
        (model/'manifest.json').write_bytes(canonical(dict(aggregate_sha256=ctx['artifact'],total_size_bytes=len(raw),
            files=[dict(path='config.json',sha256=digest(raw))])))
        prompt=self.path/'tokens.json';teacher=self.path/'teacher.json'
        prompt.write_bytes(canonical(ctx['request']['promptTokenIDs']));teacher.write_bytes(canonical(ctx['request']['teacherTokenIDs']))
        args=argparse.Namespace(command='ranks',stage_cut=cut,model_dir=model,artifact_aggregate_sha256=ctx['artifact'],
            tokens_file=prompt,tokens_sha256=digest(prompt.read_bytes()),teacher_tokens_file=teacher,
            teacher_tokens_sha256=digest(teacher.read_bytes()),chunk_size=32,baseline_jsonl=None,baseline_sha256=None)
        artifacts=Mock();result=inputs.prepare(args,output,EPOCH,artifacts)
        artifacts.verify_model.assert_called_once_with(model.resolve(),ctx['artifact']);return result

    def test_prepare_retains_only_explicit_cut_and_exact_input_history(self):
        for layers,cut in [(32,None),(32,12),(11,4)]:
            result=self.retained(layers,cut)
            self.assertEqual('stage_cut' in result,cut is not None)
            if cut is not None:self.assertEqual(result['stage_cut'],cut)
            self.assertEqual(result['request'],context(layers,cut)['request'])
        with self.assertRaises(ValueError):self.retained(11,None)

    def validate(self,ctx,values):
        for rank,value in enumerate(values):ranks.validate(value,rank,EPOCH,ctx)
        return ranks.pair(values,ctx)

    def test_unequal_storage_state_and_peer_identity_accept(self):
        for layers,cut,counts in [(32,12,[27,45]),(11,4,[9,15])]:
            ctx=context(layers,cut);values=reports(ctx);result=self.validate(ctx,values)
            self.assertEqual(result['frames_per_rank'],6);self.assertFalse(result['baseline_compared'])
            self.assertEqual([len(v['frames'][0]['capture']['stateEntries']) for v in values],counts)
            self.assertEqual(result['storage']['canonical_tensor_count'],layers+3)
            self.assertFalse(result['storage']['source_descriptor_payloads_rederived'])
            for rank,(start,end) in enumerate(stage_ranges.for_context(ctx)):
                self.assertEqual(sorted({e['globalLayerIndex'] for e in values[rank]['frames'][-1]['capture']['stateEntries']}),list(range(start,end)))

    def test_stale_half_reports_rejected_against_explicit_cut(self):
        with self.assertRaises(ValueError):self.validate(context(cut=12),reports(context()))
        with self.assertRaises(ValueError):storage.validate_pair(loads(context()),context(cut=12))
        entries,_,_=states(context(),0,32)
        with self.assertRaises(ValueError):evidence.state_entries(entries,context()['text'],0,32,12)

    def test_explicit_context_does_not_accept_changed_range_plan_or_request(self):
        ctx=context(cut=12)
        changes=[lambda r:r[0]['frames'][0]['capture'].__setitem__('sourceLayerEnd',16),
            lambda r:r[1]['frames'][0]['capture'].__setitem__('sourceLayerStart',16),
            lambda r:r[0]['sourceLoad'].__setitem__('planSHA256','f'*64),
            lambda r:r[1]['frames'][0]['capture']['identity'].__setitem__('planFingerprint','f'*64),
            lambda r:r[0]['request']['teacherTokenIDs'].__setitem__(0,9),
            lambda r:r[0].__setitem__('allRequestStateRetired',False),
            lambda r:r[1]['frames'][0].__setitem__('headerSHA256','f'*64)]
        for change in changes:
            values=reports(ctx);change(values)
            with self.assertRaises(ValueError):self.validate(ctx,values)

    def test_storage_local_reindex_ownership_coverage_and_commitments_reject(self):
        ctx=context(cut=12)
        changes=[lambda r:r[1]['activeTensors'][1].__setitem__('localName','model.layers.12.input_layernorm.weight'),
            lambda r:r[0]['activeTensors'].pop(),
            lambda r:r[1]['activeTensors'].append(copy.deepcopy(r[0]['activeTensors'][0])),
            lambda r:r[0].__setitem__('loadedTensorBytes',1),
            lambda r:r[1]['storageCommitment'].__setitem__('canonicalTensorCount',100),
            lambda r:r[0].__setitem__('storageCommitmentSHA256','f'*64)]
        for change in changes:
            value=loads(ctx);change(value)
            with self.assertRaises(ValueError):storage.validate_pair(value,ctx)

    def test_missing_duplicate_foreign_state_owner_and_frontier_reject(self):
        ctx=context(cut=12)
        for change in [lambda e:e.pop(),lambda e:e.append(copy.deepcopy(e[0])),
            lambda e:e[0].__setitem__('globalLayerIndex',11),lambda e:e[0].__setitem__('shape',[1,7,68])]:
            entries,_,_=states(ctx,1,32);change(entries)
            with self.assertRaises(ValueError):evidence.state_entries(entries,ctx['text'],1,32,12)
        entries,_,_=states(ctx,1,32)
        with self.assertRaises(ValueError):evidence.state_entries(entries,ctx['text'],1,64,12)

    def test_matching_pinned_baseline_and_stale_plan_or_numeric_baseline(self):
        ctx=context(cut=12);values=reports(ctx);row=baseline_fixture(ctx,values);path=self.path/'baseline.jsonl'
        def compare(value):
            raw=canonical(value)+b'\n';path.write_bytes(raw);ctx['baseline_sha256']=digest(raw)
            return baseline.compare(path,values,ctx)
        result=compare(row);self.assertTrue(result['exact_native_logit_bytes']);self.assertEqual(result['logit_rows'],4)
        changed=copy.deepcopy(row);changed['baseline']['source']['planSHA256']='f'*64
        with self.assertRaises(ValueError):compare(changed)
        changed=copy.deepcopy(row);changed['baseline']['frames'][0]['state']['entries'][0]['sha256']='f'*64
        with self.assertRaises(ValueError):compare(changed)
        changed=copy.deepcopy(row);changed['baseline']['frames'][2]['logits']['values'][0]=1.0
        with self.assertRaises(ValueError):compare(changed)


if __name__=='__main__':unittest.main()
