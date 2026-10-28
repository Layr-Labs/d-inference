import copy
import hashlib
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

import audit_selected_stage as audit
import selected_expected as expected_module
import stage_load_contract as outer
from arithmetic_fixture import native_arithmetic_receipt


def fabricated(e, stage):
    h = e['helper']; summaries = [dict(value, constructionConfigurationSHA256=str(i+1)*64,
                                     stagePlanSHA256=str(i+3)*64) for i,value in enumerate(e['summaries'])]
    selected = summaries[stage]
    storage = dict(schemaVersion=1,verifiedAggregateSHA256=e['artifactSHA256'],
        sourceConfigurationSHA256=e['configurationSHA256'],planSHA256='a'*64,sourceTensorManifestSHA256='b'*64,
        sourceModelTensorBytes=e['sourceBytes'],largestSourceTensorBytes=e['largestSourceBytes'],
        sourceTensorCount=len(e['source']),canonicalTensorCount=len(e['source']),bf16ConversionEnabled=True,stages=summaries)
    load = dict(schemaVersion=1,stageIndex=stage,verifiedAggregateSHA256=e['artifactSHA256'],
        sourceConfigurationSHA256=e['configurationSHA256'],planSHA256='a'*64,sourceTensorManifestSHA256='b'*64,
        sourceParameterLayoutSHA256=e['sourceLayoutSHA256'],embeddingActivationDType='bfloat16',bf16ConversionEnabled=True,
        sourceModelTensorBytes=e['sourceBytes'],largestHostTensorBytes=max(r['byteCount'] for r in e['active'][stage]),
        activeTensors=copy.deepcopy(e['active'][stage]),inertModules=copy.deepcopy(e['inert'][stage]),
        storageCommitment=storage,storageCommitmentSHA256=h.sha(h.canonical(storage)))
    for key in ['constructionConfigurationSHA256','stagePlanSHA256','parameterLayoutSHA256',
                'activeParameterLayoutSHA256','activeMappingSHA256','loadedTensorBytes','inertTensorBytes']:
        load[key] = selected[key]
    bounds = [r['byteCount']+16 for r in e['active'][stage]]
    inert = selected['inertTensorBytes']+16
    budget = dict(model=e['profile'],stageIndex=stage,profileFingerprint='c'*64,planFingerprint='a'*64,
        pairRequirementFingerprint='d'*64,selectedRequirementFingerprint='e'*64,
        activeMappingSHA256=selected['activeMappingSHA256'],active=copy.deepcopy(e['active'][stage]),
        allocationBounds=bounds,inertAllocationBound=inert,roundedResidentBytes=sum(bounds)+inert,
        largestHostTensorBytes=load['largestHostTensorBytes'],resourceAdmissionPerformed=False,forwardExecutionAuthorized=False)
    row = {key:True for key in outer.TRUE_FLAGS};row.update({key:False for key in outer.FALSE_FLAGS})
    row.update(kind='qwen_dense_stage_load_report',schemaVersion=1,model=e['profile'],stageIndex=stage,
        profileFingerprint='c'*64,selectedStageModelsLoaded=1,fullCheckpointVerificationPasses=1,
        arithmeticEnvironment=native_arithmetic_receipt(),load=load,budget=budget,
        initialResources={},loadingResources=[],releasedResources={},memory=[],runtime={})
    return row


class InventoryAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.expected = {profile:expected_module.expected(profile) for profile in outer.PROFILES}
    def setUp(self):
        self.guards = [patch('subprocess.Popen',side_effect=AssertionError('real process forbidden')),
                       patch('subprocess.run',side_effect=AssertionError('real subprocess forbidden')),
                       patch.object(socket,'socket',side_effect=AssertionError('network forbidden'))]
        for item in self.guards:item.start()
    def tearDown(self):
        for item in reversed(self.guards):item.stop()
    def replay(self,row,stage=None,profile=None):
        profile = profile or row['model'];stage = row['stageIndex'] if stage is None else stage
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'invented.jsonl';data=json.dumps(row,separators=(',',':')).encode()+b'\n';path.write_bytes(data)
            return audit.validate(path,hashlib.sha256(data).hexdigest(),profile,stage)
    def test_four_registered_stage_metadata_fixtures(self):
        for profile,e in self.expected.items():
            for stage in (0,1):
                with self.subTest(profile=profile,stage=stage):
                    result=self.replay(fabricated(e,stage))
                    self.assertTrue(result['selectedLoadedMetadataMatchesRegisteredSource'])
                    self.assertFalse(result['tensorValuesReadOrCompared'])
                    self.assertFalse(result['inertValuesOrEvaluationIndependentlyVerified'])
                    self.assertFalse(result['otherStageSummaryIsExpectedMetadataOnly'] is False)
    def test_f32_preserved_both_nine_billion_stages(self):
        e=self.expected['registered_qwen35_9b']
        for stage in (0,1):
            rows=[r for r in e['active'][stage] if r['loadedDType']=='float32']
            self.assertEqual(len(rows),12)
            self.assertTrue(all(r['sourceName'].endswith('.A_log') for r in rows))
            row=fabricated(e,stage);target=next(r for r in row['load']['activeTensors'] if r['loadedDType']=='float32')
            target['loadedDType']='bfloat16';row['budget']['active']=copy.deepcopy(row['load']['activeTensors'])
            # Re-seal the reported hashes: exact canonical dtype must still refuse.
            digest=e['helper'].sha(e['helper'].canonical(row['load']['activeTensors']))
            row['load']['activeMappingSHA256']=row['budget']['activeMappingSHA256']=digest
            row['load']['storageCommitment']['stages'][stage]['activeMappingSHA256']=digest
            row['load']['storageCommitmentSHA256']=e['helper'].sha(e['helper'].canonical(row['load']['storageCommitment']))
            with self.assertRaises(ValueError):self.replay(row)
    def test_exact_default_halves_and_global_to_local_mapping(self):
        for e in self.expected.values():
            for stage in (0,1):
                row=fabricated(e,stage)
                layer=next(r for r in row['load']['activeTensors'] if '.layers.' in r['localName'])
                layer['localName']=layer['localName'].replace('.layers.0.','.layers.99.')
                with self.assertRaises(ValueError):self.replay(row)
            row=fabricated(e,0);row['load']['activeTensors']=copy.deepcopy(e['active'][1])
            with self.assertRaises(ValueError):self.replay(row)
    def test_active_missing_duplicate_unknown_reordered(self):
        e=self.expected['registered_qwen35_9b']
        for change in ('missing','duplicate','extra','reordered'):
            row=fabricated(e,0);values=row['load']['activeTensors']
            if change=='missing':values.pop()
            elif change=='duplicate':values[-1]=copy.deepcopy(values[0])
            elif change=='extra':values[0]['unknown']=1
            else:values.reverse()
            with self.subTest(change=change),self.assertRaises(ValueError):self.replay(row)
    def test_all_audited_integer_metadata_rejects_boolean(self):
        e=self.expected['registered_qwen35_9b']
        paths=[('load','activeTensors',0,'shape',0),('load','activeTensors',0,'byteCount'),
            ('load','inertModules',0,'parameters',0,'shape',0),('load','inertModules',0,'parameters',0,'byteCount'),
            ('load','sourceModelTensorBytes'),('load','loadedTensorBytes'),('load','largestHostTensorBytes'),
            ('load','inertTensorBytes'),('load','storageCommitment','sourceTensorCount'),
            ('load','storageCommitment','stages',0,'activeTensorCount'),('budget','allocationBounds',0),
            ('budget','inertAllocationBound'),('budget','roundedResidentBytes')]
        for path in paths:
            row=fabricated(e,0);target=row
            for key in path[:-1]:target=target[key]
            target[path[-1]]=True
            with self.subTest(path=path),self.assertRaises(ValueError):self.replay(row)
    def test_loaded_shape_source_dtype_and_byte_count(self):
        e=self.expected['registered_qwen38_27b']
        for key,value in [('shape',[1]),('sourceDType','float16'),('loadedDType','float32'),('byteCount',1)]:
            row=fabricated(e,1);row['load']['activeTensors'][0][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.replay(row)
    def test_inert_exact_geometry_replacement_and_responsibility(self):
        e=self.expected['registered_qwen35_9b']
        for key,value in [('replacementKind','module-replacement'),('responsibility','invented'),('path','other')]:
            row=fabricated(e,0);row['load']['inertModules'][1][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):self.replay(row)
        row=fabricated(e,1);row['load']['inertModules'][0]['parameters'][0]['dtype']='float32'
        with self.assertRaises(ValueError):self.replay(row)
    def test_both_storage_summaries_derived_from_full_source(self):
        e=self.expected['registered_qwen35_9b'];row=fabricated(e,0)
        row['load']['storageCommitment']['stages'][1]['loadedTensorBytes']+=1
        row['load']['storageCommitmentSHA256']=e['helper'].sha(e['helper'].canonical(row['load']['storageCommitment']))
        with self.assertRaises(ValueError):self.replay(row)
    def test_layout_mapping_and_commitment_digest_mutations(self):
        e=self.expected['registered_qwen35_9b']
        for key in ['sourceParameterLayoutSHA256','parameterLayoutSHA256','activeParameterLayoutSHA256',
                    'activeMappingSHA256','storageCommitmentSHA256']:
            row=fabricated(e,0);row['load'][key]='f'*64
            with self.subTest(key=key),self.assertRaises(ValueError):self.replay(row)
    def test_allocator_metadata_bounds_and_sum(self):
        e=self.expected['registered_qwen35_9b']
        for change in ('short','low','inert','sum'):
            row=fabricated(e,0);budget=row['budget']
            if change=='short':budget['allocationBounds'].pop()
            elif change=='low':budget['allocationBounds'][0]=0
            elif change=='inert':budget['inertAllocationBound']=0
            else:budget['roundedResidentBytes']+=1
            with self.subTest(change=change),self.assertRaises(ValueError):self.replay(row)
    def test_coherent_opaque_plan_identity_has_no_independent_plan_claim(self):
        e=self.expected['registered_qwen35_9b'];row=fabricated(e,0)
        row['load']['planSHA256']=row['budget']['planFingerprint']=row['load']['storageCommitment']['planSHA256']='9'*64
        row['load']['storageCommitmentSHA256']=e['helper'].sha(e['helper'].canonical(row['load']['storageCommitment']))
        result=self.replay(row)
        self.assertFalse(result['planAndProfileSerializationIndependentlyReplayed'])
    def test_wrong_raw_pin_retains_structured_failure_new_file(self):
        e=self.expected['registered_qwen35_9b']
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'fake.jsonl';path.write_bytes(json.dumps(fabricated(e,0)).encode()+b'\n');out=Path(temp)/'audit.json'
            args=['--stdout',str(path),'--stdout-sha256','0'*64,'--profile',e['profile'],'--stage-index','0','--output',str(out)]
            with patch('builtins.print'):self.assertEqual(audit.main(args),1)
            value=json.loads(out.read_text());self.assertFalse(value['passed']);self.assertIn('raw pin',value['error'])
            self.assertEqual(out.stat().st_mode & 0o777,0o600)
            old=out.read_bytes()
            with self.assertRaises(ValueError):audit.main(args)
            self.assertEqual(out.read_bytes(),old)


if __name__=='__main__':
    unittest.main()
