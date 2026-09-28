"""New cut12 admission tests; every run, report and response is fabricated."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from rank_retrieval_fixture import encoded, make_run, reseal
from rank_sidecar_admission import admit_run
from rank_sidecar_evidence import canonical
from rank_sidecar_selection import SELECTION
from retrieve_rank_owner_sidecars import retrieve
from sidecar_files import parse, sha


class CutTests(unittest.TestCase):
    def setUp(self):
        for name in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard=patch(name,side_effect=AssertionError('No real processes or sockets'))
            guard.start();self.addCleanup(guard.stop)
        temporary=tempfile.TemporaryDirectory(prefix='rank-cut-reader-cpu-');self.addCleanup(temporary.cleanup)
        self.root=Path(temporary.name).resolve()
        self.run,self.receipt,self.pin=make_run(self.root)
        self.outputs=0

    def blocked(self, receipt):
        self.outputs+=1
        result=retrieve(self.run,reseal(self.run,receipt),self.root/('out-'+str(self.outputs)),
            reader=lambda *_:self.fail('No SSH reader may run after failed cut admission'))
        self.assertFalse(result['passed']);self.assertEqual(result['sidecars'],[])

    def test_old_namespace_and_nonexact_selected_receipt_fail_before_read(self):
        mutations=[lambda r:r.update(kind='remote_qwen_long_prefill_rank_owner_launcher'),
            lambda r:r.pop('selected_layer_plan'),
            lambda r:r['selected_layer_plan'].update(stage_cut=16),
            lambda r:r['selected_layer_plan'].update(stage_cut=12.0),
            lambda r:r['selected_layer_plan'].update(source_layer_ranges=[[0,16],[16,32]]),
            lambda r:r['selected_layer_plan'].update(extra='unadmitted'),
            lambda r:r['selected_layer_plan'].update(independent_numerical_comparison_run=True)]
        for mutate in mutations:
            receipt=copy.deepcopy(self.receipt);mutate(receipt);self.blocked(receipt)

    def test_coherent_wrong_plan_or_config_on_both_peers_cannot_bypass(self):
        paths=[self.run/('rank-'+str(rank))/'stdout.jsonl' for rank in (0,1)]
        originals=[path.read_bytes() for path in paths]
        for key in ('planFingerprint','producerStageFingerprint','consumerStageFingerprint',
                    'producerConstructionConfigurationSHA256','consumerConstructionConfigurationSHA256'):
            for path,original in zip(paths,originals):
                rows=[parse(line) for line in original.splitlines()]
                for row in rows:
                    row['agreement'][key]='f'*64
                    row['agreementFingerprint']=sha(b'qwen-profiled-prefill-start-agreement-v1\n'+canonical(row['agreement']))
                path.write_bytes(b''.join(encoded(row) for row in rows))
            self.blocked(copy.deepcopy(self.receipt))

    def test_final_source_must_match_its_selected_stage(self):
        for rank in (0,1):
            path=self.run/('rank-'+str(rank))/'stdout.jsonl';original=path.read_bytes()
            for key,value in [('planSHA256','f'*64),('stagePlanSHA256','f'*64),
                              ('constructionConfigurationSHA256','f'*64),('sourceParameterLayoutSHA256','f'*64),
                              ('sourceModelTensorBytes',5038041600.0)]:
                rows=[parse(line) for line in original.splitlines()];rows[1]['sourceLoad'][key]=value
                path.write_bytes(b''.join(encoded(row) for row in rows))
                self.blocked(copy.deepcopy(self.receipt))
            path.write_bytes(original)

    def test_exact_cut_pair_required_in_both_saved_configs(self):
        for rank in (0,1):
            path=self.run/('rank-'+str(rank))/'rank.json';original=path.read_bytes()
            initial=parse(original);index=initial['arguments'].index('--stage-cut')
            for replacement in ([],['--stage-cut','16'],['--stage-cut','12']*2):
                value=copy.deepcopy(initial);value['arguments'][index:index+2]=replacement
                path.write_bytes(encoded(value));self.blocked(copy.deepcopy(self.receipt))
            path.write_bytes(original)

    def test_new_selection_helpers_are_frozen_even_with_resealed_archive(self):
        for name in ('long_pair_cut.py','long_rank_cut.py'):
            path=self.run/'launcher'/name;original=path.read_bytes();changed=original+b'\n'
            path.write_bytes(changed);receipt=copy.deepcopy(self.receipt)
            item=next(row for row in receipt['launcher_files'] if row['path']==name)
            item.update(sha256=sha(changed),size_bytes=len(changed));self.blocked(receipt)
            path.write_bytes(original)

    def test_admitted_context_retains_selection_without_changing_trace_identity(self):
        context=admit_run(self.run,self.pin)
        self.assertEqual(context['selected_layer_plan'],SELECTION)
        self.assertEqual([row['name'] for row in context['sidecars']],['phase','owner','phase','owner'])
        self.assertEqual([row['expected_identity']['role'] for row in context['sidecars']],['rank0','rank0','rank1','rank1'])
        self.assertTrue(all(set(row['expected_identity'])=={'requestFingerprint','profile','role'}
                            for row in context['sidecars'] if row['name']=='phase'))
        self.assertFalse(context['selected_layer_plan']['independent_numerical_comparison_run'])


if __name__=='__main__':unittest.main()
