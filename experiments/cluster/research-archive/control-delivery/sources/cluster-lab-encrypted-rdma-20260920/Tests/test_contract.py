"""Fabricated report controls and local private-file checks only; no RDMA."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'package'))
from gemma_inputs import MODES,scope
from expert_results import join_results

def fixtures():
    h='a'*64
    jobs=[];reports=[]
    for rank in range(2):
        n=dict(schema='lab_authenticated_rdma_component_v1',identityKind='ssh_host_key_lab_only',
            runID='03c3eabb-e00f-4ac5-92b2-d86d838ac927',rank=rank,payloadBytes=1,warmups=3,measurements=20,
            timeoutSeconds=120,hostKeySHA256=[h,'b'*64],nativeBuildSHA256=[h,h],sourceSnapshotSHA256=h,
            mlxArtifactSHA256=h,secretCommitmentSHA256=h,expectedHardware=['fixture','fixture'],expectedOSBuild=['fixture','fixture'])
        jobs.append(dict(schema='lab_record_physical_job_v1',kind='rdma',mode='stage'+str(rank),nativeSHA256=h,timeoutSeconds=120,nativeJob=n))
        v=dict(schema='lab_authenticated_rdma_report_v1',job=n,scopeSHA256=scope(n),codec=[],copies=[],transfers=[],
            sealedRecords=47,openedRecords=47,sealedBytes=78,openedBytes=78,baselineNativeBytes=0,finalNativeBytes=0,
            maximumObservedNativeBytes=1024,baselinePhysical=dict(currentBytes=1024,lifetimeMaximumBytes=1024),
            finalPhysical=dict(currentBytes=1024,lifetimeMaximumBytes=2048),minimumObservedFreeBytes=7*1024**3,
            resourceObservations=1,nativeCacheBytesAfterRelease=0)
        for key in ['collectiveReleased','labOnly','operationTimingsIncludeExistingChecks','rank0RoundtripIsSameClock','rank1ReceiveIncludesPeerWait']:v[key]=True
        for key in ['productMembershipEstablished','productRuntimeApproved','modelExecuted','externalHTTPTTFTMeasured','processOrLeaseRetirementEstablished','keyMaterialExported','recordCodecChanged','nativeCopyCodeChanged']:v[key]=False
        for i in range(23):
            v['codec'].append(dict(ordinal=i,warmup=i<3,verified=True,sealNanoseconds=2,openNanoseconds=3,plaintextBytes=1,recordBytes=41))
            v['copies'].append(dict(ordinal=i,warmup=i<3,verified=True,exportNanoseconds=4,importNanoseconds=5,bytes=1))
        for mode in MODES:
            for i in range(23):
                def frame(direction):return dict(bytes=1 if mode=='raw_payload' else 41,
                    sha256=hashlib.sha256(f'{mode}/{i}/{direction}'.encode()).hexdigest(),nanoseconds=2)
                v['transfers'].append(dict(mode=mode,ordinal=i,warmup=i<3,verified=True,
                    firstOperationNanoseconds=4,secondOperationNanoseconds=6,roundtripNanoseconds=10,
                    sent=frame(rank),received=frame(1-rank),plaintextSHA256=hashlib.sha256(b'Y'+(b'7'*40 if mode=='raw_record_size' else b'')).hexdigest()))
        reports.append(v)
    return reports,jobs

class LabContractChecks(unittest.TestCase):
    def test_fabricated_exact_join(self):
        reports,jobs=fixtures();value=join_results(reports,jobs)
        self.assertTrue(value['labOnly']);self.assertFalse(value['productMembershipEstablished'])
        self.assertEqual(value['rank0RoundtripMedianNanoseconds']['encrypted_record'],10)
    def test_changed_ciphertext_is_not_roundtrip(self):
        reports,jobs=fixtures();reports[1]['transfers'][46]['received']['sha256']='c'*64
        with self.assertRaises(ValueError):join_results(reports,jobs)
    def test_missing_duplicate_and_timer_mismatch_refuse(self):
        for change in ('missing','ordinal','timer','boolean'):
            reports,jobs=fixtures()
            if change=='missing':reports[0]['transfers'].pop()
            elif change=='ordinal':reports[0]['transfers'][2]['ordinal']=1
            elif change=='timer':reports[0]['transfers'][2]['roundtripNanoseconds']=11
            else:reports[0]['transfers'][1]['ordinal']=True
            with self.assertRaises(ValueError):join_results(reports,jobs)
    def test_product_claim_or_frame_size_refuses(self):
        reports,jobs=fixtures();reports[0]['productMembershipEstablished']=True
        with self.assertRaises(ValueError):join_results(reports,jobs)
        reports,jobs=fixtures();reports[0]['transfers'][46]['sent']['bytes']=1
        with self.assertRaises(ValueError):join_results(reports,jobs)
    def test_scope_and_resource_refuse(self):
        reports,jobs=fixtures();reports[0]['scopeSHA256']='b'*64
        with self.assertRaises(ValueError):join_results(reports,jobs)
        reports,jobs=fixtures();reports[0]['minimumObservedFreeBytes']=6*1024**3
        with self.assertRaises(ValueError):join_results(reports,jobs)
    def test_private_file_checks_and_unlinked_stdin(self):
        import lab_secret
        original=lab_secret.REMOTE
        try:
            with tempfile.TemporaryDirectory() as directory:
                directory = str(Path(directory).resolve())
                lab_secret.REMOTE=Path(directory)
                native={'runID':'fixture','rank':0,'secretCommitmentSHA256':lab_secret.commitment(b'x'*32)}
                path=lab_secret.secret_path(native);path.parent.mkdir(mode=0o700)
                path.write_bytes(b'x'*32);path.chmod(0o644)
                with self.assertRaises(ValueError):lab_secret.install_stdin(native)
                path.chmod(0o600);path.unlink();path.symlink_to(path.parent/'missing')
                with self.assertRaises(OSError):lab_secret.install_stdin(native)
                path.unlink();path.write_bytes(b'x'*32);path.chmod(0o600)
                code='''import os,sys,json\nfrom pathlib import Path\nimport lab_secret\nlab_secret.REMOTE=Path(sys.argv[1])\nn=json.loads(sys.argv[2]);p=lab_secret.secret_path(n)\nlab_secret.install_stdin(n)\nassert not p.exists() and os.read(0,33)==b'x'*32\nprint('PASS unlinked private stdin')\n'''
                value=subprocess.run([sys.executable,'-B','-c',code,directory,json.dumps(native)],
                    env=dict(os.environ,PYTHONPATH=str(ROOT/'package')),stdin=subprocess.DEVNULL,capture_output=True,timeout=5)
                self.assertEqual(value.returncode,0);self.assertEqual(value.stdout,b'PASS unlinked private stdin\n');self.assertEqual(value.stderr,b'')
        finally:lab_secret.REMOTE=original

if __name__=='__main__':unittest.main()
