"""Entry-path staging/resource ordering with fully fake SSH/native handles."""
import contextlib
import io
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch
import launch_remote_short_ranks as launch
from prefill_compute_archive import digest, write_json
from long_rank_paths import paths
from long_rank_test_support import Child, ENDPOINTS, INPUTS, RAW_PROMPT, RAW_TEACHER, RAW_ORIGIN, RAW_PREFIX, RAW_TEXT, pinned_inputs, fixtures, write_records
from long_rank_warning import WARNING
from long_reference_inputs import ARTIFACT, CONFIGURATION


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='long-entry-cpu-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        for obj,name in [(subprocess,'Popen'),(subprocess,'run'),(socket,'socket')]:
            p=patch.object(obj,name,side_effect=AssertionError('Real process/socket forbidden'));p.start();self.addCleanup(p.stop)

    def run_fake(self,initial_pass,change_teacher_after=False):
        output=self.root/'output';runtime=self.root/'repo/experiments/cluster/runtime';runtime.mkdir(parents=True)
        release=self.root/'release';release.mkdir()
        prompt,origin=self.root/'prompt.json',self.root/'origin.json'
        prompt.write_bytes(RAW_PROMPT);origin.write_bytes(RAW_ORIGIN)
        teacher,prefix,text=self.root/'teacher.json',self.root/'prefix.json',self.root/'text.txt'
        teacher.write_bytes(RAW_TEACHER);prefix.write_bytes(RAW_PREFIX);text.write_bytes(RAW_TEXT)
        native=b'not an executable';native_pin=__import__('hashlib').sha256(native).hexdigest()
        calls=[];state={}
        def archive_sources(_runtime,out):
            base=out/'source/experiments/cluster/inference/Sources/ClusterInference';base.mkdir(parents=True)
            literal='log("'+WARNING.decode().rstrip('\n')+'")'
            (base/'Collective.swift').write_text('if transport == .loopbackTest {\n            '+literal+'\n}')
            (base/'Options.swift').write_text('func log(_ message: String) {\n    FileHandle.standardError.write(Data((message + "\\n").utf8))\n}')
            value={'files':[]};write_json(out/'source-manifest.json',value);return value
        def snapshot(_release,out):
            out.mkdir();(out/'cluster-inference').write_bytes(native)
            (out/'artifacts.py').write_text('# fake verifier never imported\n')
            files=[dict(path=p.name,sha256=digest(p),size_bytes=p.stat().st_size) for p in out.iterdir()]
            write_json(out/'bundle.json',dict(files=files));return digest(out/'bundle.json')
        def create(_processes,host,model,requested,epoch):
            layout=paths('/home/fixture',requested,model,epoch);state['layout']=layout
            return layout,dict(run=layout['run'],hostfile=ENDPOINTS,reservationOpen=False,
                method='remote_AF_INET_loopback_two_simultaneous_bind_then_close',raceFailsWithoutFallback=True)
        def upload(_processes,host,source,dest):calls.append(('upload',Path(source).name,dest))
        def start(rank):
            calls.append(('start',rank['rank']))
            config=json.loads((Path(rank['local'])/'rank.json').read_text())
            epoch=config['arguments'][config['arguments'].index('--epoch')+1]
            scheduling=None
            write_records(Path(rank['local']),fixtures(rank['rank'],scheduling,epoch=epoch),WARNING)
            return Child(7000+rank['rank'],0)
        modules={'bundle':types.SimpleNamespace(snapshot=snapshot),
                 'processes':types.SimpleNamespace(start=start,stop_processes=lambda *args:calls.append(('stop',))),
                 'artifacts':types.SimpleNamespace(verify_files=lambda *args:None)}
        class Control:
            def __init__(self,*args):self.config=json.loads((output/'controls/control-config.json').read_text())
            def call(self,operation,timeout=120):
                calls.append(('control',operation))
                if operation=='initial':return dict(passed=initial_pass,actual_free_bytes=(6 if initial_pass else 5)*1024**3)
                memory=dict(pressure_level=1,swap_used_bytes='0',remote_pid_inventory={'observed_processes':[]})
                if operation=='observe':return memory
                config=self.config
                record=dict(artifact_aggregate_sha256=ARTIFACT,bundle_manifest_sha256=config['bundle_sha256'],
                    bundle_file_sha256={r['path']:r['sha256'] for r in json.loads((output/'bundle/bundle.json').read_text())['files']},
                    model_metadata={n:dict(sha256=CONFIGURATION if n=='config.json' else 'd'*64) for n in ('config.json','manifest.json')},
                    ranks=[dict(rank=r['rank'],rank_configuration_sha256=r['rank_sha256'],raw_prompt_reencoded=False,raw_teacher_reencoded=False,
                        **{k:r[k] for k in ('prompt_sha256','prompt_size_bytes','teacher_sha256','teacher_size_bytes','hostfile_sha256','hostfile_size_bytes')}) for r in config['ranks']],
                    memory=memory)
                if operation=='before':record['posthash_preflight']={'passed':True}
                if operation=='after' and change_teacher_after:record['ranks'][1]['teacher_sha256']='f'*64
                return record
        argv=['--release',str(release),'--runtime',str(runtime),'--output',str(output),'--prompt-file',str(prompt),
            '--teacher-file',str(teacher),'--prompt-prefix-file',str(prefix),'--source-text-file',str(text),
            '--prompt-origin-file',str(origin),'--prompt-sha256',digest(prompt),'--teacher-sha256',digest(teacher),'--prompt-origin-sha256',digest(origin),
            '--artifact-aggregate-sha256',ARTIFACT,'--expected-native-sha256',native_pin,'--host','fixture-peer',
            '--remote-model-dir','/models/qwen']
        with contextlib.ExitStack() as stack:
            stack.enter_context(pinned_inputs())
            replacements=dict(archive_launcher=lambda out:[],archive_sources=archive_sources,
                load_archived_runtime=lambda *args:modules,verify_archive=lambda *args:None,create_remote=create,
                upload_new=upload,RemoteControl=Control,collect_metadata=lambda *args:[],verify_local=lambda *args:None)
            for name,value in replacements.items():stack.enter_context(patch.object(launch,name,value))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            status=launch.main(argv)
        return status,json.loads((output/'receipt.json').read_text()),calls,output

    def test_success_uploads_raw_files_only_after_initial_screen(self):
        status,receipt,calls,output=self.run_fake(True)
        self.assertEqual(status,0);self.assertTrue(receipt['passed'])
        initial=calls.index(('control','initial'));before=calls.index(('control','before'))
        uploads=[i for i,c in enumerate(calls) if c[0]=='upload' and c[1] in ('bundle','prompt.json','teacher.json','hosts.json','rank.json')]
        self.assertTrue(all(initial<i<before for i in uploads))
        self.assertEqual([c for c in calls if c[0]=='start'],[('start',0),('start',1)])
        self.assertEqual(receipt['cohort']['local_ssh_clients_reaped'],[True,True])
        self.assertFalse(receipt['cohort']['remote_process_reaping_independently_verified'])
        self.assertEqual(len(receipt['rank_files']),12)
        self.assertFalse(receipt['timing_requested']);self.assertFalse(receipt['independent_comparison_oracle_run'])
        self.assertEqual(receipt['parent_timeout_seconds'],210);self.assertEqual(receipt['native_timeout_seconds'],180)
        for rank in (0,1):
            self.assertEqual((output/('rank-'+str(rank))/'prompt.json').read_bytes(),RAW_PROMPT)
            self.assertEqual((output/('rank-'+str(rank))/'teacher.json').read_bytes(),RAW_TEACHER)
            config=json.loads((output/('rank-'+str(rank))/'rank.json').read_text())
            self.assertEqual(config['bundle'],receipt['remote_paths']['run']+'/bundle')
            self.assertEqual(config['arguments'][config['arguments'].index('--stage-cut')+1],'12')

    def test_initial_free_refusal_precedes_remote_bundle_model_and_native(self):
        status,receipt,calls,_=self.run_fake(False)
        self.assertEqual(status,1);self.assertFalse(receipt['native_execution_attempted'])
        self.assertNotIn(('control','before'),calls);self.assertFalse(any(c[0]=='start' for c in calls))
        self.assertFalse(any(c[0]=='upload' and c[1]=='bundle' for c in calls))
        self.assertIn('actual-free',receipt['primary_failure']['error'])

    def test_changed_second_teacher_after_native_success_still_fails_parent(self):
        status,receipt,calls,_=self.run_fake(True,change_teacher_after=True)
        self.assertEqual(status,1);self.assertFalse(receipt['passed']);self.assertTrue(receipt['cohort']['passed'])
        self.assertIn('Remote staged input differs: teacher_sha256',receipt['primary_failure']['error'])
        self.assertIn(('stop',),calls)


if __name__=='__main__':unittest.main()
