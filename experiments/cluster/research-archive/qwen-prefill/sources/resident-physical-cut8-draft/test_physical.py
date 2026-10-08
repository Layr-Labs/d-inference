import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from physical_common import canonical,make_jobs,read_plan,write_json
from fabricated_rank import ready,result,released,stopped
from rank_validation import RankValidator,jaccl
from remote_resident import control
from run_physical import Capture,Remote
from worker_adapter import ResidentWorkerCohort
from worker_contract import WorkerSpec,SUFFIXES,run_command,encoded

HERE=Path(__file__).parent


def setup(root):
    plan=read_plan(dict(schema='resident_physical_9b_v1',cohort_id='diagnostic:ranks',launcher_path=str(HERE),native_sha256='a'*64,
        package_sha256='b'*64,bundle_sha256='c'*64,package_members=434,coordinator='10.1.1.1:1234',devices=['rdma_en1','rdma_en1'],
        peers=[dict(host='peer%d'%r,deployment=str(root/('deploy%d'%r)),model_dir=str(root/('model%d'%r)),run_dir=str(root/('run%d'%r))) for r in (0,1)]))
    requests=[dict(request_id=plan['cohort_id']+suffix,epoch='%032x'%i) for i,suffix in enumerate(SUFFIXES,1)]
    jobs=make_jobs(plan,requests);runs=[dict(request_id=r['request_id'],phase='warmup' if i==0 else 'measured',iteration=0 if i==0 else i-1) for i,r in enumerate(requests)]
    return plan,jobs,runs


def event(kind,row,rank):return dict(type=kind,record=row)


class Contracts(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.plan,self.jobs,self.runs=setup(self.root)
    def validator(self):
        return RankValidator(self.jobs,lambda r:dict(rank=r,nativeSHA256='a'*64,nativePID=100+r),lambda r,e:'a'*64)
    def prepared(self):
        v=self.validator()
        for r in (0,1):v.identity(WorkerSpec(('x',),{},'rank',r),event('ready',ready(v,r,100+r),r),self.jobs[r]['opened'])
        return v
    def test_closed_profile_roles_and_safe_paths(self):
        for change in [lambda x:x.update(coordinator='010.1.1.1:7'),lambda x:x['peers'][1].update(host=x['peers'][0]['host']),
            lambda x:x['peers'][0].update(run_dir=x['peers'][0]['model_dir']),lambda x:x.update(package_members=True),
            lambda x:x.update(devices=['x']),lambda x:x.update(native_sha256='bad')]:
            p=copy.deepcopy(self.plan);change(p)
            with self.subTest(change=change),self.assertRaises(ValueError):read_plan(p)
    def test_jaccl_common_fingerprint_excludes_local_rank_and_path(self):
        a,b=map(jaccl,self.jobs);self.assertEqual(a['configurationFingerprint'],b['configurationFingerprint'])
        self.assertEqual(a['configurationFingerprint'],'199685b73e432ccc3b82d4afe15666cf3b5b8558f5c48c756aa0551e6fd6449c')
        changed=copy.deepcopy(self.jobs[1]);changed['coordinator']='10.1.1.2:1234'
        self.assertNotEqual(a['configurationFingerprint'],jaccl(changed)['configurationFingerprint'])
    def test_native_cli_and_wrapper_contract_sources(self):
        pins=json.loads((HERE/'native-contract-pins.json').read_bytes())
        for row in pins:self.assertEqual(hashlib.sha256((HERE/row['path']).read_bytes()).hexdigest(),row['sha256'])
        cli=(HERE/'native-contract/QwenResidentBenchmarkWorkerCLI.swift').read_text()
        self.assertIn('"--execution-path", "cbv2-contiguous"',cli)
        self.assertEqual(self.validator().cohort()['executionPath'],'cbv2-contiguous')
        report=(HERE/'native-contract/QwenLongPrefillResidentRankReport.swift').read_text()
        self.assertIn('let execution: QwenLongPrefillRankRequestResult',report)
        self.assertIn('let weightsRemainResident = true',report)
        owner=(HERE/'native-contract/QwenLongPrefillResidentRankOwner.swift').read_text()
        self.assertIn('throws -> QwenLongPrefillResidentRankRequestReport',owner)
    def test_ready_transport_source_and_cohort_drift(self):
        for change in [lambda x:x['execution'].update(transport='loopback-test'),
            lambda x:x['execution']['jacclConfiguration'].update(configuredRank=1),
            lambda x:x['execution']['cohortAgreement']['requests'][0].update(excludedWarmup=False),
            lambda x:x['execution']['cohortAgreement'].update(executionPath='native'),
            lambda x:x['execution']['sourceLoad'].update(planSHA256='0'*64),lambda x:x['runtime'].update(processID=101)]:
            v=self.validator();row=ready(v,0,100);change(row)
            with self.subTest(change=change),self.assertRaises(ValueError):v.identity(WorkerSpec(('x',),{},'rank',0),event('ready',row,0),self.jobs[0]['opened'])
    def test_four_pairs_fresh_history_and_release(self):
        v=self.prepared()
        for i,request in enumerate(self.runs):
            command=run_command(self.jobs[0]['opened'],i,request);events=[]
            for rank in (0,1):
                row=event('result',result(v,rank,command),rank);events.append(row)
                v.identity(WorkerSpec(('x',),{},'rank',rank),row,command)
            measurement=v.numerical(command,events);self.assertEqual(measurement['elapsed_ns'],100)
        for rank in (0,1):v.identity(WorkerSpec(('x',),{},'rank',rank),event('released',released(),rank),command)
        for rank in (0,1):v.identity(WorkerSpec(('x',),{},'rank',rank),event('stopped',stopped(),rank),dict(sequence=5))
        self.assertEqual(v.stopped,[True,True]);self.assertEqual(len(v.results),4)
        self.assertEqual(len({x['agreementFingerprint'] for x in v.results}),4)
    def test_cross_rank_wire_state_token_and_timing_failures(self):
        changes=[lambda row:row['execution']['execution']['frames'][0].update(envelopeWireBytesSHA256='0'*64),
            lambda row:row['execution']['execution']['finalDigest']['finalState']['entries'][0].update(sha256='0'*64),
            lambda row:row['execution']['execution'].update(selectedTokenID=1),
            lambda row:row['execution']['agreement'].update(epoch='f'*32),
            lambda row:row['execution']['execution']['actions'][1].update(action='fake')]
        for change in changes:
            v=self.prepared();command=run_command(self.jobs[0]['opened'],0,self.runs[0]);events=[]
            for rank in (0,1):
                row=result(v,rank,command)
                if rank==1:change(row)
                e=event('result',row,rank);events.append(e);v.identity(WorkerSpec(('x',),{},'rank',rank),e,command)
            with self.subTest(change=change),self.assertRaises(ValueError):v.numerical(command,events)
    def test_missing_peer_cannot_produce_measurement(self):
        v=self.prepared();command=run_command(self.jobs[0]['opened'],0,self.runs[0]);e=event('result',result(v,0,command),0)
        v.identity(WorkerSpec(('x',),{},'rank',0),e,command)
        with self.assertRaises(ValueError):v.numerical(command,[e])
    def test_remote_owner_or_ssh_exit_is_not_terminal_proof(self):
        remote=Remote(self.jobs,'d'*64,self.root)
        owner=dict(kind='owner',record=dict(nativePID=1))
        with patch.object(remote,'call',return_value=owner),patch('run_physical.time.sleep'),patch('run_physical.time.monotonic',side_effect=[0,0,2]):
            with self.assertRaises(TimeoutError):remote.terminal(0,1)
    def test_pre_native_failure_retains_no_start_without_reap_claim(self):
        from remote_resident import main
        job=self.jobs[0];run=Path(job['peer']['run_dir']);run.mkdir();write_json(run/'job.json',job)
        argv=['remote_resident.py','run','--run-dir',str(run),'--job-sha256',hashlib.sha256(canonical(job)+b'\n').hexdigest(),'--launcher-sha256','d'*64]
        with patch('sys.argv',argv),patch('remote_resident.verify_launcher'),patch('remote_resident.ResourceGate') as gate,patch('remote_resident.verify_deployment',side_effect=ValueError('wrong build')):
            gate.return_value.return_value=None
            with self.assertRaisesRegex(ValueError,'wrong build'):main()
        terminal=json.loads((run/'terminal.json').read_bytes())
        self.assertTrue(terminal['nativeNotStarted']);self.assertFalse(terminal['nativeLeaderReaped'])
        self.assertFalse(terminal['ownedGroupFenceComplete']);self.assertNotIn('owner',terminal)


class RemoteProcesses(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.plan,self.jobs,self.runs=setup(self.root)
        for job in self.jobs:Path(job['peer']['run_dir']).mkdir()
        self.jobfile=self.root/'jobs.json';write_json(self.jobfile,self.jobs)
    def one(self,rank,scenario):
        return subprocess.Popen([sys.executable,'-B',str(HERE/'fabricated_remote.py'),str(self.jobfile),str(rank),scenario],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0,start_new_session=True)
    def wait_terminal(self,rank):
        path=Path(self.jobs[rank]['peer']['run_dir'])/'terminal.json';deadline=time.monotonic()+5
        while not path.exists() and time.monotonic()<deadline:time.sleep(.02)
        self.assertTrue(path.exists(),'Remote terminal missing')
        return json.loads(path.read_bytes())
    def test_remote_eof_after_ready_reaps_native(self):
        p=self.one(0,'success')
        try:
            p.stdin.write(encoded(self.jobs[0]['opened']));p.stdin.flush();readyline=p.stdout.readline();self.assertTrue(readyline)
            p.stdin.close();p.wait(timeout=5);terminal=self.wait_terminal(0)
            self.assertEqual(terminal['status'],'failed');self.assertTrue(terminal['nativeLeaderReaped']);self.assertTrue(terminal['ownedGroupFenceComplete'])
            self.assertIn('input ended',terminal['primaryFailure'])
        finally:
            if p.poll() is None:os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=2)
            p.stdout.close();p.stderr.close()
    def test_cancel_during_native_wait_reaps_remote_group(self):
        p=self.one(0,'hang')
        try:
            p.stdin.write(encoded(self.jobs[0]['opened']));p.stdin.flush();self.assertTrue(p.stdout.readline())
            command=run_command(self.jobs[0]['opened'],0,self.runs[0]);p.stdin.write(encoded(command));p.stdin.flush()
            response=control(self.jobs[0],'cancel');self.assertFalse(response['remoteRetirementConfirmed'])
            p.wait(timeout=5);terminal=self.wait_terminal(0)
            self.assertTrue(terminal['nativeLeaderReaped']);self.assertTrue(terminal['ownedGroupFenceComplete']);self.assertEqual(terminal['completedRequests'],0)
        finally:
            if p.poll() is None:os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=2)
            p.stdin.close();p.stdout.close();p.stderr.close()
    def test_stream_hash_error_still_retains_terminal_and_reaping(self):
        p=self.one(0,'hash_fail')
        try:
            opened=self.jobs[0]['opened'];p.stdin.write(encoded(opened));p.stdin.flush();self.assertTrue(p.stdout.readline())
            for index,request in enumerate(self.runs):
                p.stdin.write(encoded(run_command(opened,index,request)));p.stdin.flush();self.assertTrue(p.stdout.readline())
            self.assertTrue(p.stdout.readline())
            p.stdin.write(encoded(dict(schema=opened['schema'],type='shutdown',cohort_id=opened['cohort_id'],sequence=5)));p.stdin.flush()
            self.assertTrue(p.stdout.readline());p.wait(timeout=5);terminal=self.wait_terminal(0)
            self.assertEqual(terminal['status'],'failed');self.assertTrue(terminal['nativeLeaderReaped'])
            self.assertTrue(terminal['ownedGroupFenceComplete'])
            self.assertEqual(terminal['postflightErrors'][0]['operation'],'retained_stream_hashes')
        finally:
            if p.poll() is None:os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=2)
            p.stdin.close();p.stdout.close();p.stderr.close()
    def test_both_remote_supervisors_complete_four_permitted_requests(self):
        output=self.root/'client';output.mkdir();capture=Capture(output)
        def owner(rank):return json.loads((Path(self.jobs[rank]['peer']['run_dir'])/'owner.json').read_bytes())
        v=RankValidator(self.jobs,owner,capture)
        specs=[WorkerSpec((sys.executable,'-B',str(HERE/'fabricated_remote.py'),str(self.jobfile),str(rank),'success'),
            dict(PATH='/usr/bin:/bin',PYTHONDONTWRITEBYTECODE='1'),'rank',rank) for rank in (0,1)]
        cohort=ResidentWorkerCohort(specs,self.plan['cohort_id'],self.jobs[0]['opened']['requests'],output/'pipes',15,lambda phase:None,v.identity,v.numerical)
        with cohort:
            self.assertEqual(v.ordinal,0)
            for request in self.runs:cohort.run(request)
        self.assertEqual(v.stopped,[True,True])
        for rank in (0,1):
            terminal=self.wait_terminal(rank);self.assertEqual(terminal['status'],'completed')
            self.assertEqual(terminal['nativeExitCodes'],[0]);self.assertTrue(terminal['ownedGroupFenceComplete'])
            for item in terminal['streams']:
                raw=(output/('pipes/worker-%d.%s'%(rank,item['stream']))).read_bytes()
                self.assertEqual(hashlib.sha256(raw).hexdigest(),item['sha256'])


if __name__=='__main__':unittest.main()
