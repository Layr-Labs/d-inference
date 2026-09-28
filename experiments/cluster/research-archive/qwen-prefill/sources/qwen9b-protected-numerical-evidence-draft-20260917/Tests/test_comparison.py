"""Fabricated CPU values only; no actual native/reference output is read."""
import copy
from pathlib import Path
import struct
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import compare_evidence as c

class ComparisonTests(unittest.TestCase):
    def fixture(self):
        h = lambda n: str(n) * 64
        expected = dict(publicRequestID='11111111-1111-4111-8111-111111111111',
            nativeRequestID='22222222-2222-4222-8222-222222222222',
            membershipEpoch='33333333-3333-4333-8333-333333333333',rankBuildSHA256=[h(1),h(1)],
            resourcePolicySHA256=c.RESOURCE_POLICY_SHA)
        entries=[]
        for layer in range(32):
            if (layer+1)%4:
                parts=[('conv',[1,3,8192],'bfloat16',49152),('ssm',[1,32,128,128],'float32',2097152)]
            else:
                parts=[('kv.keys',[1,4,33,256],'bfloat16',67584),('kv.position_offsets',[1],'int32',4),
                       ('kv.values',[1,4,33,256],'bfloat16',67584)]
            for component,shape,dtype,size in parts:
                entries.append(dict(globalLayerIndex=layer,component=component,shape=shape,dtype=dtype,byteCount=size,sha256=h(2)))
        values=[0.0]*248320;values[4]=1.0
        raw=bytearray(496640);raw[8:10]=struct.pack('<H',0x3f80)
        row=dict(shape=[1,248320],dtype='bfloat16',byteCount=496640,logicalBytesSHA256=c.digest(raw),values=values)
        reference=dict(requestID=expected['publicRequestID'].upper(),profile=dict(fingerprint=h(8)),promptCount=32,chunkSize=16,requestedOutputCount=2,
            committedTokens=33,completedFrames=3,allRequestStateRetired=True,stopTokenIDs=[],
            source=dict(sourceConfigurationSHA256=h(3),artifactAggregateSHA256=h(4),planSHA256=h(5),arithmeticEnvironmentSHA256=h(6)),
            promptTokenIDsSHA256=h(7),selectedTokenIDs=[3,4],finalLogits=row,
            finalState=dict(entries=entries,fingerprint=c.state_fingerprint(entries)))
        sides=[]
        for rank in range(2):
            local=[e for e in entries if rank*16<=e['globalLayerIndex']<(rank+1)*16]
            request=c.digest(('qwen-stage-generation-request-v1\n'+h(8)+'\n'+expected['nativeRequestID']
                +'\nprompt='+h(7)+'\nchunk=16\noutput=2\nstop=').encode())
            side=dict(schema='qwen9b_protected_final_evidence_v1',nativeRequestID=expected['nativeRequestID'],
                membershipEpoch=expected['membershipEpoch'],rank=rank,sourceLayerStart=rank*16,sourceLayerEnd=(rank+1)*16,
                requestFingerprint=request,profileFingerprint=h(8),agreementFingerprint=h(9),sourceConfigurationSHA256=h(3),
                artifactAggregateSHA256=h(4),storageCommitmentSHA256=h(1),planFingerprint=h(5),numericalPolicySHA256=h(6),
                protectedResourcePolicySHA256=c.RESOURCE_POLICY_SHA,stageFingerprints=[h(2),h(3)],rankBuildSHA256=expected['rankBuildSHA256'],
                promptTokenIDsSHA256=h(7),promptCount=32,chunkSize=16,outputCount=2,prefillSchedule='serial_v1',stopTokenIDs=[],
                selectedTokenIDs=[3,4],selectedTokenIDsSHA256=c.token_hash([3,4]),tokenChainSHA256=h(2),completedFrames=3,
                committedTokens=33,finishReason='length',bothRequestStatesRetired=True,logicalStateBytes=sum(e['byteCount'] for e in local),
                stageStateSHA256=c.state_fingerprint(local),stateEntries=local,finalLogits=row if rank else None,
                captureBudget=dict(originalRequestReservedBytes=1000,logicalRowBytes=496640*rank,float32RowBytes=993280*rank,
                    extraHostBytes=1489920*rank,extraNativeBytes=1489920*rank,protectedReservedBytes=c.PROTECTED_BYTES,
                    exportHostAllowanceBytes=10*1048576,maximumEncodedBytes=8*1048576,
                    totalReservedBytes=1000+2979840*rank+c.PROTECTED_BYTES),
                captureResourceObservationCount=3,minimumCaptureActualFreeBytes=8*1024**3,minimumCaptureAllocatorLimitBytes=20*1024**3,
                correctnessOnly=True,throughputMeasurementValid=False,stateBytesIncluded=False,intermediateLogitRowsCompared=False,
                independentNumericalComparisonPerformed=False,ownerCleanupIndependentlyVerified=False,wholeProcessPeakProven=False,servingEnabled=False)
            self.assertEqual(set(side),c.SIDE_FIELDS);sides.append(side)
        return reference,sides,expected

    def testCompleteFullRowAndSeventyTwoDisjointComponents(self):
        reference,sides,expected=self.fixture()
        result=c.compare(reference,sides,expected)
        self.assertEqual(result['comparedStateEntries'],72)
        self.assertEqual(result['comparedVocabularyValues'],248320)
        self.assertFalse(result['ownerCleanupQualified'])

    def testActualNativeIdentityAndPolicyCannotBeRelabelled(self):
        for field,value in [('nativeRequestID','44444444-4444-4444-8444-444444444444'),
                            ('membershipEpoch','44444444-4444-4444-8444-444444444444'),
                            ('protectedResourcePolicySHA256','a'*64),('requestFingerprint','a'*64),
                            ('selectedTokenIDs',[3,5]),('servingEnabled',True)]:
            reference,sides,expected=self.fixture();sides[1][field]=value
            with self.assertRaises(ValueError):c.compare(reference,sides,expected)

    def testComponentLossOverlapDigestChangeAndFullRowMutationRefuse(self):
        for kind in ('missing','overlap','digest','boolean-shape','row','nonfinite','unknown'):
            reference,sides,expected=self.fixture();sides=copy.deepcopy(sides)
            if kind=='missing':sides[1]['stateEntries'].pop()
            elif kind=='overlap':sides[1]['stateEntries'][0]=sides[0]['stateEntries'][0]
            elif kind=='digest':sides[1]['stateEntries'][0]['sha256']='a'*64
            elif kind=='boolean-shape':sides[1]['stateEntries'][0]['shape'][0]=True
            elif kind=='row':sides[1]['finalLogits']['values'][0]=1.0
            elif kind=='nonfinite':sides[1]['finalLogits']['values'][0]=float('nan')
            else:sides[0]['unexpected']=True
            with self.assertRaises(ValueError):c.compare(reference,sides,expected)

    def testDuplicateAndNonfiniteJSONAndReportedBytesRefuse(self):
        for raw in ('{"rank":0,"rank":1}','{"value":NaN}'):
            with self.assertRaises(ValueError):c.strict_json(raw)
        reference,sides,expected=self.fixture();sides[1]['captureBudget']['totalReservedBytes']-=1
        with self.assertRaises(ValueError):c.compare(reference,sides,expected)

if __name__=='__main__':unittest.main()
