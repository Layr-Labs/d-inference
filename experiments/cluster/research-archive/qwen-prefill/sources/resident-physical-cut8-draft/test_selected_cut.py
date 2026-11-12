"""Metadata and fabricated state regressions; no new native candidate inputs."""
import copy
from pathlib import Path
import unittest
from unittest.mock import patch

import selected_source as selected
import cut12_pair_final as final
import cut12_pair_storage as storage
from physical_common import native_spec, validate_job
from rank_validation import PureContext, RankValidator
from stage_checks.common import parse
from test_physical import setup

HERE=Path(__file__).parent


class SelectedCut(unittest.TestCase):
    def setUp(self):
        self.catalog=parse((HERE/'selection/catalog.json').read_bytes())
        self.retained=parse((HERE/'selection/retained-inputs.json').read_bytes())['nine']
        self.names=parse((HERE/'selection/canonical-names.json').read_bytes())
        self.control=parse((HERE/'qualified-source-controls.json').read_bytes())

    def derive(self,cut=8):
        return selected.derive(self.catalog,self.retained,self.names,self.control,cut)

    def test_pinned_cut8_complete_inventory_and_f32(self):
        value=selected.load();loads=value['loads']
        self.assertEqual(value['ranges'],[[0,8],[8,32]])
        self.assertEqual([len(r['activeTensors']) for r in loads],[233,694])
        self.assertEqual([r['loadedTensorBytes'] for r in loads],[1545572992,3492468608])
        self.assertEqual([sum(t['loadedDType']=='float32' for t in r['activeTensors']) for r in loads],[6,18])
        names=[t['sourceName'] for r in loads for t in r['activeTensors']]
        self.assertEqual(len(names),len(set(names)));self.assertEqual(set(names),set(self.names))
        self.assertEqual(sum(r['loadedTensorBytes'] for r in loads),5038041600)
        self.assertEqual(loads[0]['storageCommitment'],loads[1]['storageCommitment'])
        self.assertEqual(loads[0]['storageCommitmentSHA256'],loads[1]['storageCommitmentSHA256'])

    def test_recipe_reproduces_both_qualified_cut12_receipts(self):
        # Independent historical expected metadata, not produced by this recipe.
        self.assertEqual(self.derive(12)['loads'],self.control['loads'])

    def test_wrong_missing_duplicate_candidate_refused(self):
        for change in [lambda rows:rows.remove(next(c for c in rows if c['cut']==8)),
                       lambda rows:rows.append(copy.deepcopy(next(c for c in rows if c['cut']==8))),
                       lambda rows:next(c for c in rows if c['cut']==8).update(cut=True)]:
            saved=copy.deepcopy(self.catalog);change(self.catalog['candidates'])
            with self.assertRaises(ValueError):self.derive()
            self.catalog=saved
        for cut in (True,8.0,7,16):
            with self.assertRaises(ValueError):self.derive(cut)

    def test_wrong_source_local_owner_and_duplicate_mapping_refused(self):
        changes=[lambda s:s['parameters'][0].update(stage=1),
                 lambda s:s['parameters'][0].update(localName='language_model.model.layers.99.norm.weight'),
                 lambda s:s['parameters'].append(copy.deepcopy(s['parameters'][0])),
                 lambda s:s['parameters'].pop(),
                 lambda s:s.update(sourceLayerRange=[0,12]),
                 lambda s:s['state'][0]['layer'].update(localIndex=1)]
        for change in changes:
            saved=copy.deepcopy(self.catalog);change(next(c for c in self.catalog['candidates'] if c['cut']==8)['stages'][0])
            with self.subTest(change=change),self.assertRaises(ValueError):self.derive()
            self.catalog=saved

    def test_retained_tensor_dtype_bytes_and_types_refused(self):
        changes=[lambda r:r.update(sourceDType='F16'),lambda r:r.update(byteCount=True),
                 lambda r:r['shape'].__setitem__(0,True),lambda r:r.update(name='unknown.weight')]
        for change in changes:
            saved=copy.deepcopy(self.retained);r=next(r for r in self.retained['canonicalTensors'] if r['sourceDType']=='F32');change(r)
            with self.subTest(change=change),self.assertRaises(ValueError):self.derive()
            self.retained=saved

    def test_source_raw_pin_checked_before_derivation(self):
        original=selected.snapshot
        def changed(path,*args,**kwargs):
            value=original(path,*args,**kwargs)
            if str(path).endswith('catalog.json'):value['sha256']='0'*64
            return value
        with patch.object(selected,'snapshot',side_effect=changed),self.assertRaisesRegex(ValueError,'pin differs'):
            selected.load()

    def test_exact_native_cut_pair_and_wrong_job_refused(self):
        _,jobs,_=setup(Path('/tmp/cut8-source-fixture'))
        for job in jobs:
            argv,_,_=native_spec(job)
            self.assertEqual(job['cut'],8);self.assertEqual(argv.count('--stage-cut'),1)
            self.assertEqual(argv[argv.index('--stage-cut')+1],'8')
            self.assertEqual(argv[argv.index('--timeout-seconds')+1],'300')
            self.assertEqual(job['supervisor_seconds'],315)
            for cut in (12,True,8.0):
                bad=copy.deepcopy(job);bad['cut']=cut
                with self.assertRaises(ValueError):validate_job(bad)
                with self.assertRaises(ValueError):native_spec(bad)
        jobs[1]['cut']=12
        with patch('rank_validation.Reference',side_effect=AssertionError('reference IO occurred')):
            with self.assertRaisesRegex(ValueError,'Both jobs'):RankValidator(jobs,None,None)

    def context(self):
        a=PureContext();a.selection=self.derive();entries=[]
        # Independent full-global fake, without consulting selected stage lists.
        for layer in range(32):
            parts=[('kv.keys',[1,4,8192,256],'bfloat16',16777216),
                   ('kv.values',[1,4,8192,256],'bfloat16',16777216),
                   ('kv.position_offsets',[1],'int32',4)] if layer%4==3 else [
                   ('conv',[1,3,8192],'bfloat16',49152),('ssm',[1,32,128,128],'float32',2097152)]
            entries += [dict(globalLayerIndex=layer,component=n,shape=s,dtype=d,byteCount=b,
                             sha256=a.sha((str(layer)+'|'+n).encode())) for n,s,d,b in parts]
        entries.sort(key=lambda e:(e['globalLayerIndex'],e['component']))
        reference=dict(execution=dict(finalState=dict(entries=entries),request=dict(steps=[dict(frame={})])))
        summary={k:'a'*64 for k in ('recordedRequestFingerprint','requestFingerprint','profileFingerprint',
                    'arithmeticEnvironmentSHA256','promptFileSHA256','promptTokenIDsSHA256')}
        summary['finalLogits']=dict(shape=[1,248320],dtype='bfloat16',byteCount=496640,sha256='b'*64)
        loads=a.selection['loads'];identities=[storage.identity(a,r,loads[r],summary) for r in (0,1)]
        return a,reference,summary,loads,identities,'c'*64

    def finals(self,c):
        a,ref,summary,loads,ids,fp=c
        return [final.expected_final(a,r,ref,summary,loads[r],ids[r],fp) for r in (0,1)]

    def test_dynamic_final18_54_complete72_union(self):
        c=self.context();rows=self.finals(c)
        self.assertEqual([len(r['finalState']['entries']) for r in rows],[18,54])
        self.assertEqual([r['finalState']['logicalByteCount'] for r in rows],[79986696,239960088])
        a,ref,summary,loads,ids,fp=c
        self.assertEqual(final.check_finals(a,rows,ref,summary,loads,ids,fp),a.state_fingerprint(ref['execution']['finalState']['entries']))

    def test_missing_duplicate_and_cross_boundary_reference_refused(self):
        for change in [lambda es:es.pop(0),lambda es:es.append(copy.deepcopy(es[0])),
                       lambda es:es[0].update(globalLayerIndex=8),lambda es:es[0].update(dtype='float32'),
                       lambda es:es[0].update(byteCount=True)]:
            c=self.context();change(c[1]['execution']['finalState']['entries'])
            with self.subTest(change=change),self.assertRaises(ValueError):self.finals(c)

    def test_missing_duplicate_reordered_or_changed_candidate_final_refused(self):
        for change in [lambda es:es.pop(0),lambda es:es.append(copy.deepcopy(es[0])),
                       lambda es:es.reverse(),lambda es:es[0].update(sha256='0'*64),
                       lambda es:es[0].update(globalLayerIndex=7)]:
            c=self.context();rows=self.finals(c);change(rows[1]['finalState']['entries'])
            a,ref,summary,loads,ids,fp=c
            with self.subTest(change=change),self.assertRaises(ValueError):final.check_finals(a,rows,ref,summary,loads,ids,fp)

    def test_stale_final_plan_and_old27_45_partition_refused(self):
        c=self.context();c[3][0]['planSHA256']=self.control['loads'][0]['planSHA256']
        with self.assertRaises(ValueError):self.finals(c)
        c=self.context();rows=self.finals(c);entries=c[1]['execution']['finalState']['entries']
        rows[0]['finalState']['entries']=[e for e in entries if e['globalLayerIndex']<12]
        rows[1]['finalState']['entries']=[e for e in entries if e['globalLayerIndex']>=12]
        a,ref,summary,loads,ids,fp=c
        with self.assertRaises(ValueError):final.check_finals(a,rows,ref,summary,loads,ids,fp)


if __name__=='__main__':unittest.main()
