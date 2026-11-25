"""Fabricated CPU parser controls only; no physical or cryptographic proof."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('smoke',ROOT/'validate_smoke.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class SmokeJoinTests(unittest.TestCase):
    def fixture(self,root):
        h=lambda b:hashlib.sha256(b).hexdigest()
        cap=b'fixture capability';resource=b'fixture resource';native=h(b'native');plan=h(b'plan')
        epoch=uuid.uuid4();devices=[{'serial':'fixture0','sePublicKeySHA256':h(b'se0')},{'serial':'fixture1','sePublicKeySHA256':h(b'se1')}]
        desc={'schema':'qwen9b_protected_runtime_description_v1','staticProfile':'qwen9b_short_records_experiment_v1','bootstrapProfile':'native_key_prelude_mesh2_v1',
              'stageCut':16,'promptTokens':32,'chunkTokens':16,'outputTokens':2,'prefillSchedule':'serial_v1','stopTokenIDs':[],
              'runtimeBinarySHA256':native,'selectedPlanSHA256':plan,'capabilitySHA256':h(cap),'resourcePolicySHA256':h(resource),
              'ordinaryCapabilityBase64':base64.b64encode(cap).decode(),'resourcePolicyBase64':base64.b64encode(resource).decode()}
        approval={'ID':'fixture','NativeRuntimeSHA256':list(bytes.fromhex(native)),'PlanSHA256':list(bytes.fromhex(plan)),
                  'CapabilitySHA256':list(bytes.fromhex(h(cap))),'ResourcePolicySHA256':list(bytes.fromhex(h(resource)))}
        c={'schema':'native_shared_hardware_coordinator_v1','devices':devices,'approval':approval}
        packet={}
        def write(role,value):
            data=(json.dumps(value,sort_keys=True)+'\n').encode();path=root/(role+'.json');path.write_bytes(data)
            packet[role]={'path':str(path),'sha256':h(data)}
        write('description',desc);write('coordinatorConfig',c)
        l={'schema':'native_shared_hardware_leader_v1','tlsConfigurationSHA256':h(b'fixture explicit TLS config'),'nativeSHA256':native,'cliSHA256':h(b'cli'),'descriptorSHA256':packet['description']['sha256'],
           'capabilitySHA256':h(cap),'resourcePolicySHA256':h(resource),'planSHA256':plan,'configurationSHA256':h(b'config'),'nativePeerIDs':['rank0','rank1']}
        write('leaderConfig',l)
        reserved={k:v for k,v in l.items() if k!='schema'}
        reserved.update(schema='native_shared_hardware_leader_result_v1',configurationFileSHA256=packet['leaderConfig']['sha256'],
            publicRequestID=m.PUBLIC_ID,cbv2RequestID=1,nativeRequestID=str(uuid.uuid4()),membershipEpoch=str(epoch),
            inputBindingSHA256=m.INPUT,requestSHA256=m.REQUEST,referenceSHA256=m.REFERENCE,reservedBytes=7,readyCapacityBytes=9,hardwareSmokeOnly=True,numericallyQualified=False)
        result=dict(reserved,tokenIDs=[1654,421],requestRetired=True,bytesInUseAfterRelease=0,retainedOwnerShutdownReturned=True,success=True)
        obs={'epoch':epoch.hex,'devices':devices,'providerIDs':['actual-fixture-connection0','actual-fixture-connection1'],
             'providerBinarySHA256':[l['cliSHA256']]*2,'nativeSHA256':native,'planSHA256':plan,'approvalID':'fixture',
             'phase':'released','released':[True,True],'committed':True,'keyConfirmed':[True,True],'meshRound':4,'workerReady':[True,True],
             'relayWritersEnded':True,'cancellationPublished':True,'aggregatePublicationEnded':True,'aggregatePublicationFailed':[False,False],
             'startSHA256':[h(b'start0'),h(b'start1')],'workerRecords':[5,5],'workerBytes':[500,500],'connectionClosed':[True,False]}
        cr={'schema':'native_shared_hardware_coordinator_result_v1','success':True,'error':'','configSHA256':packet['coordinatorConfig']['sha256'],'observation':obs}
        write('reserved',reserved);write('leaderResult',result);write('coordinatorResult',cr)
        return packet,write,result,cr
    def test_complete_join_is_smoke_only(self):
        with tempfile.TemporaryDirectory() as directory:
            packet,*_=self.fixture(Path(directory).resolve());result=m.check(packet)
            self.assertTrue(result['success']);self.assertFalse(result['numericallyQualified']);self.assertFalse(result['physicalPostflightValidated'])
    def test_changed_actual_inner_id_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            packet,write,result,_=self.fixture(Path(directory).resolve());result['nativeRequestID']=str(uuid.uuid4());write('leaderResult',result)
            with self.assertRaises(ValueError):m.check(packet)
    def test_publication_failure_does_not_erase_distinct_owner_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            packet,write,_,cr=self.fixture(Path(directory).resolve());cr['observation']['aggregatePublicationFailed'][1]=True;write('coordinatorResult',cr)
            with self.assertRaises(ValueError):m.check(packet)
    def test_new_epoch_and_unretired_bytes_fail(self):
        for change in ('epoch','bytes'):
            with tempfile.TemporaryDirectory() as directory:
                packet,write,result,cr=self.fixture(Path(directory).resolve())
                if change=='epoch':cr['observation']['epoch']=uuid.uuid4().hex;write('coordinatorResult',cr)
                else:result['bytesInUseAfterRelease']=7;write('leaderResult',result)
                with self.assertRaises(ValueError):m.check(packet)
    def test_integer_flags_and_duplicate_json_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            packet,write,_,cr=self.fixture(Path(directory).resolve())
            cr['observation']['released']=[1,1];write('coordinatorResult',cr)
            with self.assertRaises(ValueError):m.check(packet)
        with self.assertRaises(ValueError):m.decode(b'{"x":true,"x":false}')
        with self.assertRaises(ValueError):m.decode(b'{"x":NaN}')

if __name__=='__main__':unittest.main()
