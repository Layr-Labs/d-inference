"""Invented records, files and process objects only; no native/model/network IO."""
import copy
import hashlib
import json
import os
from pathlib import Path
import socket
import tempfile
import types
import unittest
from unittest.mock import patch
import short_parity_contract as contract
import run_short_parity as parent

PROFILE='registered_qwen35_9b'
BATTERY="Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t19%; discharging; 1:00 remaining present: true\n"
AC="Now drawing from 'AC Power'\n"
PROMPT=b'[ 1, 2, 3 ]\n';TEACHER=b'[4]\n'
TOKENS=dict(prompt=dict(sizeBytes=len(PROMPT),sha256=hashlib.sha256(PROMPT).hexdigest(),tokenIDs=[1,2,3]),
            teacher=dict(sizeBytes=len(TEACHER),sha256=hashlib.sha256(TEACHER).hexdigest(),tokenIDs=[4]))


def rows(profile=PROFILE):
    p=contract.PROFILES[profile];plan='a'*64;layout='b'*64;profile_fp='c'*64;evidence='d'*64;storage='e'*64
    uid='11111111-2222-4333-8444-555555555555'
    g=contract.fingerprint(['qwen-stage-request-v1|'+uid+'|3|2|2'])
    history=contract.fingerprint(['qwen-layer-stage-recorded-request-v1',g,'vocabulary=248320','prompt=1,2,3','teacher=4'])
    admission=contract.fingerprint(['registered-dense-short-reference-admission-v1',profile,p['configuration'],p['manifest'],p['artifact'],plan,
        history,TOKENS['prompt']['sha256'],TOKENS['teacher']['sha256'],'prompt=3|chunk=2|teacher=1|output=2|capacity=5'])
    coords=[dict(sequence=i,phase='prefill' if i<2 else 'decode',tokenOffset=[0,2,3][i],tokenCount=[2,1,1][i],finalPromptChunk=i==1) for i in range(3)]
    source=dict(artifactAggregateSHA256=p['artifact'],sourceConfigurationSHA256=p['configuration'],sourceParameterLayoutSHA256=layout,
        planSHA256=plan,bf16ConversionEnabled=True,embeddingActivationDType='bfloat16',sourceModelTensorBytes=p['sourceBytes'],layerCount=p['layers'],vocabularySize=248320)
    request=dict(request=dict(requestID=uid.upper(),promptCount=3,chunkSize=2,outputCount=2),vocabularySize=248320,
        promptTokenIDs=[1,2,3],teacherTokenIDs=[4],steps=[dict(frame=f,tokenIDs=ids) for f,ids in zip(coords,[[1,2],[3],[4]])],fingerprint=history)
    frames=[];compframes=[]
    for i,f in enumerate(coords):
        frame=dict(frame=f,committedTokens=[2,3,4][i],outputKind='evaluation_handle' if i==0 else 'logits',
            outputShape=[1,1 if i==0 else 248320],outputDType='bfloat16',state={'opaqueFakeState':True})
        comp=dict(frame=f,committedTokens=[2,3,4][i],stateMetadataAndDigestsExact=True)
        if i:frame['logits']={'opaqueFakeRow':[0]};comp.update(logits={'opaqueFakeRow':[1]},nativeLogitBytesExact=True)
        frames.append(frame);compframes.append(comp)
    baseline=dict(kind='qwen_layer_stage_recorded_baseline',correctnessOnly=True,throughputMeasurementValid=False,
        request=request,source=source,frames=frames,fingerprint=evidence,allRequestStateRetired=True)
    load=dict(schemaVersion=1,verifiedAggregateSHA256=p['artifact'],configurationSHA256=p['configuration'],parameterLayoutSHA256=layout,
        sourceModelTensorBytes=p['sourceBytes'],loadedTensorBytes=p['sourceBytes'],tensorCount=p['canonicalTensorCount'],bf16ConversionEnabled=True)
    common=dict(model=profile,profileFingerprint=profile_fp,planFingerprint=plan,recordedRequestFingerprint=history,
        promptSHA256=TOKENS['prompt']['sha256'],teacherSHA256=TOKENS['teacher']['sha256'],maximumTokens=5,resourceAdmissionPerformed=False,forwardExecuted=False)
    fullbudget=dict(common,role='fullReference',admissionFingerprint=admission)
    pairbudget=dict(common,role='sequentialStagePair',referenceAdmissionFingerprint=admission)
    first={k:True for k in contract.BASE_TRUE};first.update({k:False for k in contract.BASE_FALSE})
    first.update(contract.GEOMETRY,kind='qwen_dense_short_baseline_checkpoint',schemaVersion=1,model=profile,
        referenceAdmissionFingerprint=admission,promptSHA256=TOKENS['prompt']['sha256'],teacherSHA256=TOKENS['teacher']['sha256'],
        baseline=baseline,load=load,budget=fullbudget,initialResources={},releasedResources={},resourceObservations=[],memory=[],runtime={},fullModelsLoaded=1,fullCheckpointVerificationPasses=1)
    loads=[dict(schemaVersion=1,stageIndex=i,verifiedAggregateSHA256=p['artifact'],sourceConfigurationSHA256=p['configuration'],
        planSHA256=plan,sourceParameterLayoutSHA256=layout,sourceModelTensorBytes=p['sourceBytes'],bf16ConversionEnabled=True,
        embeddingActivationDType='bfloat16',storageCommitmentSHA256=storage) for i in range(2)]
    comparison=dict(kind='qwen_layer_stage_recorded_comparison',correctnessOnly=True,throughputMeasurementValid=False,sequentialOneProcessOnly=True,
        nativeBoundaryBytesCopied=True,baselineEvidenceSHA256=evidence,requestSHA256=history,source=copy.deepcopy(source),stageStorageCommitmentSHA256=storage,frames=compframes,allRequestStateRetired=True)
    pair={k:True for k in contract.PAIR_TRUE};pair.update(comparison=comparison,stageLoads=loads,budget=pairbudget,
        initialResources={},releasedResources={},resourceObservations=[],memory=[],runtime={},stageModelsLoaded=2,fullCheckpointVerificationPasses=1,physicalBufferLineageAttested=False)
    last={k:True for k in contract.FINAL_TRUE};last.update({k:False for k in contract.FINAL_FALSE})
    last.update(contract.GEOMETRY,kind='qwen_dense_short_parity_report',schemaVersion=1,model=profile,
        referenceAdmissionFingerprint=admission,recordedRequestFingerprint=history,promptSHA256=TOKENS['prompt']['sha256'],teacherSHA256=TOKENS['teacher']['sha256'],baselineEvidenceSHA256=evidence,pair=pair)
    return [first,last]


def raw(values):return b''.join(json.dumps(v,separators=(',',':')).encode()+b'\n' for v in values)


def sample(pid=None,executable=None):
    x=dict(actualFreeBytes=8*contract.GIB,pressureLevel=1,reportedSwapBytes='0.00',nativeRSSBytes=None,missingRSSIsNotZero=True)
    if pid is not None:x.update(nativePID=pid,nativePGID=pid,nativeRSSBytes=3*contract.GIB,nativeCommand=str(executable)+' --mode qwen-dense-short-parity-check --model-dir /fake')
    return x


class FakeProcess:
    pid=91234
    def __init__(self,code=0):self.returncode=None;self.code=code
    def poll(self):return self.returncode
    def wait(self,timeout=None):self.returncode=self.code;return self.returncode


class ParityTests(unittest.TestCase):
    def setUp(self):
        self.guards=[patch('subprocess.Popen',side_effect=AssertionError('real process forbidden')),
            patch('subprocess.run',side_effect=AssertionError('real subprocess forbidden')),patch.object(socket,'socket',side_effect=AssertionError('network forbidden'))]
        for p in self.guards:p.start()
    def tearDown(self):
        for p in reversed(self.guards):p.stop()
    def test_two_profiles_outer_only(self):
        for profile in contract.PROFILES:
            result=contract.validate_result(raw(rows(profile)),profile,TOKENS)
            self.assertTrue(result['outerIdentityAndScopeValidated']);self.assertFalse(result['independentNumericalAuditPerformed'])
            self.assertFalse(result['independentPlanSerializationReplayed']);self.assertFalse(result['nativeResourceSamplesIndependentlyAudited'])
        # The deliberately different/minimal fake rows pass outer identity only.
        self.assertNotEqual(rows()[0]['baseline']['frames'][1]['logits'],rows()[1]['pair']['comparison']['frames'][1]['logits'])
    def test_order_counts_and_complete_records(self):
        a,b=rows()
        for values in [[a],[b],[b,a],[a,b,b],[]]:
            with self.assertRaises(ValueError):contract.validate_result(raw(values),PROFILE,TOKENS)
        data=raw([a,b])
        for changed in [data[:-1],data+b'\n',data.replace(b'"schemaVersion":1',b'"schemaVersion":1,"schemaVersion":1',1),data.replace(b'"runtime":{}',b'"runtime":NaN',1),data.replace(b'"runtime":{}',b'"runtime":1e309',1)]:
            with self.assertRaises(ValueError):contract.validate_result(changed,PROFILE,TOKENS)
    def test_exact_closed_outer_keys_and_flags(self):
        cases=[(0,'schemaVersion',True),(0,'fullModelsLoaded',2),(0,'fullModelReleasedBeforeStageLoading',False),(1,'completed',False),
            (1,'numericalParityEstablished',False),(1,'wholeProcessMemorySafetyEstablished',True),(1,'outputCount',2.0),(1,'model','other')]
        for i,key,value in cases:
            r=rows();r[i][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):contract.validate_result(raw(r),PROFILE,TOKENS)
        for i in (0,1):
            r=rows();r[i]['unknown']=0
            with self.assertRaises(ValueError):contract.validate_result(raw(r),PROFILE,TOKENS)
    def test_history_raw_source_and_budget_joins(self):
        paths=[(0,'promptSHA256'),(1,'teacherSHA256'),(0,'referenceAdmissionFingerprint'),(1,'recordedRequestFingerprint'),
            (0,'baseline','request','fingerprint'),(0,'baseline','source','artifactAggregateSHA256'),
            (1,'pair','comparison','requestSHA256'),(1,'pair','comparison','baselineEvidenceSHA256'),
            (1,'pair','stageLoads',1,'planSHA256'),(1,'pair','budget','profileFingerprint'),(0,'budget','role')]
        for path in paths:
            r=rows();v=r
            for key in path[:-1]:v=v[key]
            v[path[-1]]='f'*64
            with self.subTest(path=path),self.assertRaises(ValueError):contract.validate_result(raw(r),PROFILE,TOKENS)
        r=rows();r[0]['baseline']['request']['promptTokenIDs'][0]=True
        with self.assertRaises(ValueError):contract.validate_result(raw(r),PROFILE,TOKENS)
    def test_incomplete_baseline_and_failed_comparison(self):
        for path in [(0,'baseline','allRequestStateRetired'),(1,'pair','stageModelsReleased'),(1,'pair','comparison','allRequestStateRetired')]:
            r=rows();v=r
            for k in path[:-1]:v=v[k]
            v[path[-1]]=False
            with self.assertRaises(ValueError):contract.validate_result(raw(r),PROFILE,TOKENS)
        for i,key in [(0,'baseline'),(1,'pair')]:
            r=rows();values=r[i][key] if i==0 else r[i][key]['comparison'];values['frames'].pop()
            with self.assertRaises(ValueError):contract.validate_result(raw(r),PROFILE,TOKENS)
        for key,value in [('stateMetadataAndDigestsExact',False),('nativeLogitBytesExact',False),('committedTokens',True)]:
            r=rows();r[1]['pair']['comparison']['frames'][1][key]=value
            with self.assertRaises(ValueError):contract.validate_result(raw(r),PROFILE,TOKENS)
    def test_per_record_and_total_including_lf(self):
        self.assertEqual((contract.MAX_RECORD,contract.MAX_STDOUT),(32*1024**2,64*1024**2))
        with patch.object(contract,'MAX_RECORD',16),patch.object(contract,'MAX_STDOUT',32):
            contract.check_record_bytes(b'x'*15+b'\n'+b'y'*15+b'\n',True)
            contract.check_record_bytes(b'x'*15,False)
            for data in [b'x'*16,b'x'*16+b'\n',b'x'*15+b'\n'+b'y'*15+b'\n'+b'x']:
                with self.assertRaises(ValueError):contract.check_record_bytes(data,False)
    def test_token_files_regular_raw_exact_counts_and_pins(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);p=d/'p';t=d/'t';p.write_bytes(PROMPT);t.write_bytes(TEACHER)
            data,pins=contract.token_inputs(p,t,TOKENS['prompt']['sha256'],TOKENS['teacher']['sha256'])
            self.assertEqual(data,(PROMPT,TEACHER));self.assertEqual(pins,TOKENS)
            with self.assertRaises(ValueError):contract.token_file(p,'0'*64,3)
            for bad in [b'[]',b'[true,2,3]',b'[1.0,2,3]',b'[1,2,248320]',b'[1,2,-1]',b' '*4097,b'']:
                p.write_bytes(bad)
                with self.assertRaises(ValueError):contract.token_file(p,hashlib.sha256(bad).hexdigest(),3)
            link=d/'link';link.symlink_to(t)
            with self.assertRaises(OSError):contract.token_file(link,TOKENS['teacher']['sha256'],1)
            fifo=d/'fifo';os.mkfifo(fifo)
            with self.assertRaises(ValueError):contract.token_file(fifo,TOKENS['teacher']['sha256'],1)
    def test_exact_eight_pair_command_and_parent_flags(self):
        cmd=contract.native_command('/exe','/model',PROFILE,'/p','/t',TOKENS['prompt']['sha256'],TOKENS['teacher']['sha256'])
        self.assertEqual(len(cmd),17);self.assertEqual(cmd[1:5],['--mode','qwen-dense-short-parity-check','--model-dir','/model'])
        self.assertEqual(cmd[-2:],['--timeout-seconds','120'])
        args=['--runtime','/r/experiments/cluster/runtime','--release','/release','--model-dir','/model','--profile',PROFILE,
            '--tokens-file','/p','--tokens-sha256',TOKENS['prompt']['sha256'],'--teacher-tokens-file','/t','--teacher-tokens-sha256',TOKENS['teacher']['sha256'],
            '--expected-native-sha256','a'*64,'--output','/out']
        self.assertEqual(parent.parse_args(args).tokens_file,Path('/p'))
        with self.assertRaises(ValueError):parent.parse_args(args+['--reuse-bundle','/bundle'])
        with patch('sys.stderr'),self.assertRaises(SystemExit):parent.parse_args(args+['--stage-index','0'])
    def test_unchanged_resource_and_power_screens(self):
        for key,value in [('actualFreeBytes',contract.MINIMUM_FREE-1),('actualFreeBytes',True),('pressureLevel',3),('reportedSwapBytes','1')]:
            with self.assertRaises(ValueError):contract.resource_policy(dict(sample(),**{key:value}),contract.PROFILES[PROFILE])
        exe=Path('/fake/exe')
        for p in contract.PROFILES.values():
            x=dict(sample(10,exe),nativeRSSBytes=p['maximumSampledRSSBytes']);contract.resource_policy(x,p,10,exe)
            with self.assertRaises(ValueError):contract.resource_policy(dict(x,nativeRSSBytes=x['nativeRSSBytes']+1),p,10,exe)
        for change in [dict(nativePID=11),dict(nativePGID=True),dict(nativeCommand='/fake/exe --mode qwen-dense-stage-load-check '),dict(nativeRSSBytes=True)]:
            with self.assertRaises(ValueError):contract.resource_policy(dict(sample(10,exe),**change),contract.PROFILES[PROFILE],10,exe)
        self.assertEqual(contract.power_policy(AC)['source'],'AC Power')
        self.assertEqual(contract.power_policy(BATTERY.replace('19%','15%'))['batteryPercent'],15)
        with self.assertRaises(ValueError):contract.power_policy(BATTERY.replace('19%','14%'))
    def test_defunct_identity_and_resource_not_bypassed(self):
        exe=Path('/fake/exe');value=dict(sample(10,exe),nativeRSSBytes=0,nativeCommand='<defunct>')
        contract.resource_policy(value,contract.PROFILES[PROFILE],10,exe,terminal_exit_code=0)
        for code in [None,True,0.0]:
            with self.assertRaises(ValueError):contract.resource_policy(value,contract.PROFILES[PROFILE],10,exe,terminal_exit_code=code)
        for changes in [dict(nativeRSSBytes=1),dict(nativePID=11),dict(nativePGID=11),dict(actualFreeBytes=0),dict(nativeCommand='<defunct> extra')]:
            with self.assertRaises(ValueError):contract.resource_policy(dict(value,**changes),contract.PROFILES[PROFILE],10,exe,terminal_exit_code=0)

    def flow(self, reuse=False, native_code=0, fail_sample=None, sample_change=None,
             source_post_failure=False, reuse_post_failure=False, cleanup_error=False, mutate_raw=False, stderr=b'',
             stream_pin_failure=False, output_change=None, mutate_tokens=False):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve(); repo = base / 'repo'; runtime = repo / 'experiments/cluster/runtime'
            runtime.mkdir(parents=True); release = base / 'release'; release.mkdir()
            (release / 'cluster-inference').write_bytes(b'FAKE BINARY - NEVER EXECUTED')
            model = base / 'model'; model.mkdir(); (model / 'config.json').write_bytes(b'{ "fake": 1 }\n')
            (model / 'manifest.json').write_bytes(b'{"fakeManifest":1}\n')
            profile = dict(contract.PROFILES[PROFILE], configuration=parent.sha(model / 'config.json'),
                           manifest=parent.sha(model / 'manifest.json'))
            out = base / 'result'; native_sha = parent.sha(release / 'cluster-inference')
            prompt_file, teacher_file = base / 'prompt.json', base / 'teacher.json'
            prompt_file.write_bytes(PROMPT); teacher_file.write_bytes(TEACHER)
            args = types.SimpleNamespace(runtime=runtime, release=release, model_dir=model, profile=PROFILE,
                tokens_file=prompt_file, teacher_tokens_file=teacher_file, tokens_sha256=TOKENS["prompt"]["sha256"],
                teacher_tokens_sha256=TOKENS["teacher"]["sha256"], expected_native_sha256=native_sha, output=out,
                reuse_bundle=base / 'external' if reuse else None,
                expected_bundle_manifest_sha256='c' * 64 if reuse else None)
            calls = dict(samples=0, verify=0, create=0, reference=0, cleanup=0, popen=0, snapshot=0)
            def observed(pid=None):
                calls['samples'] += 1; value = sample(pid, out / 'bundle/cluster-inference')
                if calls['samples'] == fail_sample: value.update(sample_change or {'actualFreeBytes': 0})
                return value
            def stop(process):
                calls['cleanup'] += 1
                if process.returncode is None: process.returncode = -15
                return ['invented cleanup failure'] if cleanup_error else []
            tiny = types.SimpleNamespace(sample=observed, read_command=lambda cmd: BATTERY if 'pmset' in cmd[0] else '',
                ENVIRONMENT={'DARKBLOOM_BF16_WEIGHTS':'1','DARKBLOOM_CBV2_ATTN_QUERY_BLOCK':'128','MLX_ENABLE_TF32':'1'},
                stop_owned=stop, owned_group=lambda pid: [])
            def write_json(path, value):
                path.write_text(json.dumps(value)); path.chmod(0o600)
            def archive_sources(runtime, output):
                (output / 'source/experiments/cluster/runtime').mkdir(parents=True)
                value = dict(files=[{'fake':True}]); write_json(output / 'source-manifest.json', value); return value
            def snapshot(source, dest):
                calls['snapshot'] += 1; dest.mkdir(); (dest / 'cluster-inference').write_bytes((source / 'cluster-inference').read_bytes())
                return 'c' * 64
            def verify(*a):
                calls['verify'] += 1
                if calls['verify'] > 1 and source_post_failure: raise ValueError('invented source postflight failure')
            modules = dict(bundle=types.SimpleNamespace(snapshot=snapshot), artifacts=object())
            archive = types.SimpleNamespace(write_json=write_json, archive_sources=archive_sources,
                load_archived_runtime=lambda *a: modules, verify_archive=verify)
            def create_reference(source, dest, manifest_pin, executable_pin, archived_runtime, artifacts):
                calls['create'] += 1
                self.assertEqual((manifest_pin, executable_pin), ('c' * 64, native_sha))
                self.assertEqual(archived_runtime, out / 'source/experiments/cluster/runtime')
                source.mkdir(); (source / 'cluster-inference').write_bytes((release / 'cluster-inference').read_bytes())
                dest.symlink_to(source, target_is_directory=True)
                return dict(manifestSHA256='c' * 64)
            def check_reference(*a):
                calls['reference'] += 1
                if calls['reference'] > 1 and reuse_post_failure: raise ValueError('invented reference postflight failure')
            reference = types.SimpleNamespace(create_reference=create_reference, check_reference=check_reference)
            def launch(command, **kwargs):
                calls['popen'] += 1
                self.assertTrue(kwargs['start_new_session']); self.assertEqual(kwargs['cwd'], out / 'bundle')
                self.assertEqual(kwargs['stdin'], parent.subprocess.DEVNULL)
                self.assertEqual(command, contract.native_command(out / 'bundle/cluster-inference', model, PROFILE, out / 'prompt.json', out / 'teacher.json', TOKENS['prompt']['sha256'], TOKENS['teacher']['sha256']))
                self.assertEqual(kwargs['env']['DARKBLOOM_BF16_WEIGHTS'], '1')
                self.assertNotIn('DARKBLOOM_FAKE', kwargs['env'])
                self.assertEqual((out / 'prompt.json').read_bytes(), PROMPT); self.assertEqual((out / 'teacher.json').read_bytes(), TEACHER)
                value = rows(); value = output_change(value) if output_change else value
                kwargs['stdout'].write(raw(value)); kwargs['stdout'].flush()
                kwargs['stderr'].write(stderr); kwargs['stderr'].flush()
                if mutate_tokens: prompt_file.write_bytes(b'[5,6,7]')
                if mutate_raw: (model / 'config.json').write_bytes(b'changed after initial raw pin')
                return FakeProcess(native_code)
            bounded = parent.bounded_regular
            stream_reads = []
            def bounded_stream(path, limit):
                stream_reads.append(path)
                if stream_pin_failure and len(stream_reads) == 2:
                    raise ValueError('invented changed stream during postflight')
                return bounded(path, limit)
            with patch.dict(contract.PROFILES, {PROFILE: profile}), patch.object(parent, 'import_pinned',
                side_effect=lambda n: {'tiny_support.py':tiny,'prefill_compute_archive.py':archive,'owned_bundle_reference.py':reference}[n]), \
                patch.object(parent.subprocess, 'Popen', side_effect=launch), patch.dict(parent.os.environ, {'DARKBLOOM_FAKE':'x'}), \
                patch.object(parent, 'bounded_regular', side_effect=bounded_stream):
                receipt = parent.run(args)
            self.assertEqual((out / 'receipt.json').stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads((out / 'receipt.json').read_text())['status'], receipt['status'])
            return receipt, calls

    def test_fake_snapshot_and_reuse_success(self):
        for reuse in (False,True):
            receipt,calls=self.flow(reuse=reuse)
            self.assertEqual(receipt['status'],'completed');self.assertEqual(calls['popen'],1);self.assertEqual(calls['cleanup'],1)
            self.assertEqual(calls['snapshot'],int(not reuse));self.assertEqual(calls['reference'],2 if reuse else 0)
            self.assertTrue(receipt['nativeReaped']);self.assertFalse(receipt['independentNumericalAuditPerformed'])
            self.assertTrue(receipt['tokenFilesArchivedWithoutReencoding'])
    def test_prelaunch_and_live_resource_refusal(self):
        for point in (1,2,3):
            receipt,calls=self.flow(fail_sample=point)
            self.assertEqual(receipt['status'],'failed');self.assertIn('Actual free memory',receipt['primaryFailure'])
            self.assertEqual(calls['popen'],int(point==3))
            if point==3:self.assertTrue(receipt['nativeReaped']);self.assertEqual(calls['cleanup'],1)
    def test_nonzero_stderr_and_incomplete_baseline_remain_failure(self):
        for kw in [dict(native_code=1),dict(stderr=b'normal-looking diagnostic\n'),dict(output_change=lambda r:r[:1]),
                   dict(output_change=lambda r:list(reversed(r)))]:
            receipt,calls=self.flow(**kw)
            self.assertEqual(receipt['status'],'failed');self.assertTrue(receipt['primaryFailure']);self.assertTrue(receipt['nativeReaped'])
    def test_native_failed_comparison_is_not_completed(self):
        def changed(r):r[1]['pair']['comparison']['frames'][2]['nativeLogitBytesExact']=False;return r
        receipt,_=self.flow(output_change=changed)
        self.assertEqual(receipt['status'],'failed');self.assertIn('native logit',receipt['primaryFailure'])
    def test_cleanup_and_independent_postflight_errors_retained(self):
        receipt,calls=self.flow(reuse=True,cleanup_error=True,source_post_failure=True,reuse_post_failure=True)
        self.assertEqual(receipt['status'],'failed');self.assertTrue(receipt['cleanupErrors'])
        actions={r['action'] for r in receipt['postRunErrors']}
        self.assertIn('source_archive_bundle_recheck',actions);self.assertIn('reused_bundle_reference_recheck',actions)
        self.assertEqual(calls['reference'],2)
    def test_original_metadata_and_tokens_rechecked(self):
        for kw,action in [(dict(mutate_raw=True),'raw_metadata_recheck'),(dict(mutate_tokens=True),'original_token_recheck')]:
            receipt,_=self.flow(**kw)
            self.assertEqual(receipt['status'],'failed');self.assertIn(action,{x['action'] for x in receipt['postRunErrors']})
    def test_stream_pin_error_does_not_erase_receipt(self):
        receipt,_=self.flow(stream_pin_failure=True)
        self.assertEqual(receipt['status'],'failed');self.assertIn('retained_stream_pin_stdout.jsonl',{x['action'] for x in receipt['postRunErrors']})
    def test_observation_and_final_validation_charge_deadline(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp);(out/'stdout.jsonl').write_bytes(raw(rows()));(out/'stderr.log').write_bytes(b'')
            for values,message in [([135],'after observation'),([0,0,135],'after output validation')]:
                process=FakeProcess();receipt=dict(registeredProfile=PROFILE,rawTokenInputs=TOKENS,memorySamples=[],powerObservations=[])
                tiny=types.SimpleNamespace(sample=lambda pid:sample(pid,out/'bundle/cluster-inference'),read_command=lambda cmd:BATTERY)
                clock=iter(values)
                with self.assertRaisesRegex(ValueError,message):
                    parent.supervise(process,out,tiny,receipt,contract.PROFILES[PROFILE],lambda:None,clock=lambda:next(clock),deadline=135)
    def test_owned_exit_observation_preserves_terminal_confirmation(self):
        process=FakeProcess();process.returncode=0
        observation=dict(sample(process.pid,Path('/fake')),nativeCommand='<defunct>',nativeRSSBytes=0)
        tiny=types.SimpleNamespace(sample=lambda pid:dict(observation),read_command=lambda cmd:BATTERY)
        receipt=dict(memorySamples=[],powerObservations=[])
        value=parent.observe(tiny,receipt,contract.PROFILES[PROFILE],process,Path('/fake'))
        self.assertEqual(value['terminalExitCodeObservedAfterSample'],0)
        self.assertFalse(value['defunctSampleIsLiveRSS'])


if __name__=='__main__':unittest.main()
