"""CPU schema/exact-native controls; no actual result, model or process fixture."""
import copy
from pathlib import Path
import struct
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'proposed'),str(ROOT/'proposed/package'),str(ROOT.parent/'harness-target-width-v1'),str(ROOT.parent/'harness-target-width-v1/package')]
from target_width_contract import POLICY,FLAGS,MODES,ROW_ORDINALS,SAMPLE_FLAGS,text_hash,token_hash,validate_result
from target_width_compare import mismatch


def fixture():
    job=dict(mode='full',promptCount=128,chunkSize=64,outputCount=16,cut=7,prefillPolicy='serial',
        residualDType='bfloat16',captureEvidence=True,requestIDs=['id'+str(i) for i in range(4)])
    ids=list(range(16));scope='a'*64;files=[];samples=[]
    def record(name):return dict(name=name,bytes=4,sha256='b'*64)
    for ordinal,mode in enumerate(MODES):
        request=('%064x' % (ordinal+1));prefix=f'request-{ordinal}-width-{mode.lower()}'
        rows=[]
        for out in ROW_ORDINALS:
            if out==0:base,width,keep=64,64,64
            elif out in (1,15) or ordinal in (0,1):base,width,keep=127+out,1,1
            elif ordinal==2:base,width,keep=129,3,3
            else:base,width,keep=127+out,3,1
            rows.append(dict(outputOrdinal=out,logicalInputFrontier=128+out,evaluatedWindowBase=base,
                evaluatedWindowWidth=width,retainedWindowInputs=keep,argmax=ids[out],file=record(f'{prefix}-row-{out}.json')))
        entries=[dict(globalLayerIndex=i,localLayerIndex=i,component=c,file=record(f'{prefix}-state-{i}-{c}.bin'))
            for i in range(30) for c in ('kv.keys','kv.position_offsets','kv.values')]
        files.extend([r['file'] for r in rows[:-1]]+[s['file'] for s in entries]+[rows[-1]['file']])
        samples.append(dict(SAMPLE_FLAGS,ordinal=ordinal,requestID=job['requestIDs'][ordinal],
            ordinaryRequestScopeSHA256=text_hash([scope,'iteration='+str(ordinal),request]),mode=mode,
            projectionPolicy='ordinary_m1_bypass' if ordinal<2 else POLICY,
            requestSHA256=request,forcedInputSequence=ids[:15],actualTargetArgmax=ids.copy(),expectedGreedyIDs=ids.copy(),
            allArgmaxMatchReference=True,checkpointFrontier=132,rows=rows,checkpointState=dict(frontier=132,entries=entries),
            binding={},referenceGeneratedInThisSession=ordinal==0,teacherForcedInputs=ordinal!=0))
    value=dict(FLAGS,schema='gemma4_target_width_qualification_result_v1',benchmarkJob=job,
        ordinaryInputScopeSHA256=scope,scopeSHA256='',planSHA256='c'*64,
        sourceLoad=dict(target='full-reference',selectedTensorCount=1339,sourceTensorCount=1697,planSHA256='c'*64),
        referenceRequestID='id0',referenceRequestSHA256=samples[0]['requestSHA256'],referenceSelectedTokenIDs=ids,
        referenceSelectedTokenIDsSHA256=token_hash(ids),modes=list(MODES),samples=samples,
        resources=dict(completedTensorCount=1339,selectedTensorCount=1339,minimumActualFreeBytes=6*1024**3,
            operationalResourceChecksApplied=True,actualAllocatorBoundsUsed=True,newServingActivationFloorEstablished=False),
        targetResources=dict(policy='gemma4_mtp_remote_target_resources_v1',assistantLoadedOnTarget=False,servingFloorChanged=False,
            wholeProcessPeakBoundEstablished=False,physicalRetirementEstablished=False,requestSHA256=samples[0]['requestSHA256'],
            budgetSHA256='d'*64,observations=1,minimumActualFreeBytes=6*1024**3,maximumObservedActiveBytes=0,
            hostBytes=16*1024**2+32768,baseTerms=[dict(name=str(i),logicalBytes=1,allocationBound=16384) for i in range(30)],
            baseNativeBytes=30*16384,verificationTerms=[dict(name='verify',logicalBytes=1,allocationBound=16384)],verificationNativeBytes=16384),
        files=files,diagnosticRequests=4,referenceRequests=1,comparisonRequests=3,checkpointFrontier=132,
        rowsPerRequest=6,stateComponentsPerRequest=90,allActualTargetArgmaxMatchReference=True,nativeCacheBytesAfterRelease=0,
        guardMetrics=dict(schema='gemma4_guard_wall_counters_v1',overflow=False),guardObservationPolicy='gemma4_invocation_fresh_observation_v1')
    value['denseProjection']=dict(policy=POLICY,expectedDenseModules=235,expectedTiedHeads=1,serialHeadLogicalBytes=4*1024**2,
        gatheredOverrideEnabled=False,singleRowOverrideEnabled=False,wholeModelNumericsQualified=False)
    extra=value['targetResources']
    extra['baseTerms'] += [dict(name='serialTargetHead:row'+str(i),logicalBytes=1024**2,allocationBound=1024**2) for i in range(4)]
    extra['baseNativeBytes'] += 4*1024**2
    extra['budgetSHA256']=text_hash(['gemma4_mtp_remote_target_resources_v1',extra['requestSHA256'],
        'maximumFrontier=143','depth=2','buffer=5','host='+str(extra['hostBytes'])]
        +[x['name']+':'+str(x['logicalBytes'])+':'+str(x['allocationBound']) for x in extra['baseTerms']])
    value['scopeSHA256']=text_hash(['gemma4_target_width_qualification_v1',scope,'reference='+value['referenceRequestSHA256'],
        'tokens='+token_hash(ids),'checkpoint=132','assistant=false','performance=false']+list(MODES)+[POLICY])
    return value,job

class Checks(unittest.TestCase):
    def reject(self,change):
        value,job=fixture();change(value)
        with self.assertRaises((ValueError,AssertionError,RuntimeError,KeyError,TypeError)):validate_result(value,job)
    def test_complete_schema(self):
        value,job=fixture();self.assertIs(validate_result(value,job),value)
    def test_numerical_mismatch_is_retained_not_native_kill(self):
        value,job=fixture();sample=value['samples'][2]
        sample['actualTargetArgmax'][2]=21;sample['rows'][2]['argmax']=21
        sample['allArgmaxMatchReference']=False;value['allActualTargetArgmaxMatchReference']=False
        self.assertIs(validate_result(value,job),value)
    def test_changed_mode(self):self.reject(lambda x:x['samples'][2].update(mode=MODES[1]))
    def test_wrong_retained_width(self):self.reject(lambda x:x['samples'][3]['rows'][2].update(retainedWindowInputs=3))
    def test_changed_forced_packet(self):self.reject(lambda x:x['samples'][1].update(forcedInputSequence=[9]*15))
    def test_sidecar_order(self):self.reject(lambda x:x['files'].reverse())
    def test_missing_state(self):self.reject(lambda x:x['samples'][1]['checkpointState']['entries'].pop())
    def test_resource_undercharge(self):self.reject(lambda x:x['targetResources'].update(verificationNativeBytes=0))
    def test_wrong_dense_policy(self):self.reject(lambda x:x['denseProjection'].update(policy='ordinary'))
    def test_hooked_ordinary_refuses(self):self.reject(lambda x:x['samples'][0].update(projectionPolicy=POLICY))
    def test_hooked_width_one_refuses(self):self.reject(lambda x:x['samples'][1].update(projectionPolicy=POLICY))
    def test_gathered_override_refuses(self):self.reject(lambda x:x['denseProjection'].update(gatheredOverrideEnabled=True))
    def test_missing_module_coverage(self):self.reject(lambda x:x['denseProjection'].update(expectedDenseModules=234))
    def test_missing_head_charge(self):self.reject(lambda x:x['targetResources']['baseTerms'].pop())
    def test_native_signed_zero_is_not_equal(self):
        a=struct.pack('<ff',0.0,1.0);b=struct.pack('<ff',-0.0,1.0)
        self.assertEqual(mismatch(a,b,'float32'),dict(exact=False,differentNativeElements=1,firstDifferentElement=0))
    def test_native_bfloat16_low_bit_is_not_equal(self):
        self.assertEqual(mismatch(struct.pack('<H',0x3f80),struct.pack('<H',0x3f81),'bfloat16')['differentNativeElements'],1)
    def test_different_native_byte_count_refused(self):
        with self.assertRaises((ValueError,AssertionError,RuntimeError)):mismatch(b'\0\0',b'\0\0\0\0','bfloat16')

if __name__=='__main__':unittest.main()
