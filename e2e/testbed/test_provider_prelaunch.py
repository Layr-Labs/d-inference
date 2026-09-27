"""CPU-only prelaunch control-pipe tests with synthetic host observations."""
from pathlib import Path
import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
import provider_host as host


class PrelaunchLifecycle(unittest.TestCase):
    def run_prelaunch(self, kind, operation, deadline=1, lease=1, initial=b''):
        with tempfile.TemporaryDirectory() as temporary:
            base=Path(temporary).resolve();root=base/'owned';marker=base/'provider-started'
            ready={'hardware_model':'MacFixture,1','memory_bytes':36<<30,'gpu_temperature_c':30,'load1':1,'free_bytes':200<<30,'unexpected_processes':[],'owned_processes':[]}
            target={'hardware_model':'MacFixture,1','memory_bytes':36<<30}
            command=[sys.executable,'-c',"from pathlib import Path;import time;Path("+repr(str(marker))+").write_text('started');time.sleep(300)"]
            script="""import sys,time,os
from pathlib import Path
sys.path.insert(0,IMPORT)
import provider_host as h
ready=READY
count=0
def observation(target):
 global count
 count+=1
 if KIND=='slow_ready':
  h.send({'event':'sampling'})
  time.sleep(.1)
 value=dict(ready)
 if KIND=='foreign':value['unexpected_processes']=[99999]
 elif KIND=='disk':value['free_bytes']=100*(1<<30)
 elif KIND=='identity':value['hardware_model']='different'
 elif KIND=='nonfinite':value['gpu_temperature_c']=float('nan')
 elif KIND=='hot' or (KIND=='transient' and count==1):value['gpu_temperature_c']=42.75
 return value
h.observe=observation
def prepare(checkpoint,launch,record):
 h.wait_for_entry(TARGET,checkpoint,h.send,record,interval=.02)
 checkpoint()
 root=Path(ROOT)
 root.mkdir()
 launch.update(root=root,command=COMMAND,environment=dict(os.environ))
 if KIND=='staged':
  h.send({'event':'staged'})
  checkpoint(.1)
r=h.run_owner(None,None,None,sys.stdin.buffer,h.send,prepare_launch=prepare,prelaunch_seconds=DEADLINE,lease_seconds=LEASE,initial_control=INITIAL)
sys.exit(0 if r['failure'] is None else 2)
"""
            for key,value in {'IMPORT':str(Path(host.__file__).parent),'READY':ready,'KIND':kind,'TARGET':target,'ROOT':str(root),'COMMAND':command,'DEADLINE':deadline,'LEASE':lease,'INITIAL':initial}.items():script=script.replace(key,repr(value))
            owner=subprocess.Popen([sys.executable,'-u','-c',script],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            events=[]
            try:
                operation(owner,events)
                stdout,stderr=owner.communicate(timeout=4)
                events += [json.loads(line) for line in stdout.splitlines()]
                terminals=[e for e in events if e['event']=='terminal'];self.assertEqual(len(terminals),1,stderr)
                terminal=terminals[0];self.assertTrue(terminal['group_cleanup_complete'])
                if terminal['provider_started']:
                    with self.assertRaises(ProcessLookupError):os.kill(terminal['pid'],0)
                else:
                    self.assertIsNone(terminal['pid']);self.assertIsNone(terminal['exit_code']);self.assertFalse(marker.exists());self.assertEqual(root.exists(),terminal['root_created'])
                return terminal,events,owner.returncode
            finally:
                if owner.poll() is None:owner.kill();owner.wait(timeout=3)
                if owner.stdin is not None:owner.stdin.close()
                owner.stdout.close();owner.stderr.close()

    @staticmethod
    def read_until(owner,events,event):
        while True:
            row=json.loads(owner.stdout.readline());events.append(row)
            if row['event']==event:return row

    def test_transient_heat_waits_for_ready_then_starts_one_owned_child(self):
        def stop(owner,events):
            self.read_until(owner,events,'started');owner.stdin.write('{"command":"stop"}\n');owner.stdin.flush()
        row,events,code=self.run_prelaunch('transient',stop)
        checks=[e for e in events if e['event']=='entry']
        self.assertEqual([e['entry_ready'] for e in checks],[False,True]);self.assertEqual(checks[0]['observation']['gpu_temperature_c'],42.75)
        self.assertIn('42 C',checks[0]['entry_reason']);self.assertTrue(row['provider_started']);self.assertEqual(code,0)

    def test_prelaunch_timeout_preserves_actual_last_refusal(self):
        row,_,code=self.run_prelaunch('hot',lambda owner,events:owner.wait(timeout=3),deadline=.08)
        self.assertEqual(code,2);self.assertIn('prelaunch deadline',row['failure']);self.assertEqual(row['entry_observation']['gpu_temperature_c'],42.75)

    def test_foreign_process_disk_and_identity_refuse_before_staging(self):
        for kind,reason in [('foreign','processes'),('disk','disk'),('identity','identity')]:
            with self.subTest(kind=kind):
                row,events,code=self.run_prelaunch(kind,lambda owner,events:owner.wait(timeout=3))
                self.assertEqual(code,2);self.assertIn(reason,row['entry_reason']);self.assertFalse(events[0]['retryable'])

    def test_nonfinite_refusal_is_json_safe_and_retains_measurement_error(self):
        row,events,code=self.run_prelaunch('nonfinite',lambda owner,events:owner.wait(timeout=3))
        self.assertEqual(code,2)
        self.assertEqual(row['entry_observation']['measurement_errors']['gpu_temperature_c'],'nan')
        self.assertIsNone(events[0]['observation']['gpu_temperature_c'])
        self.assertFalse(events[0]['entry_ready'])

    def test_stop_already_buffered_prevents_preparation(self):
        row,events,code=self.run_prelaunch('transient',lambda owner,events:owner.wait(timeout=3),initial=b'{"command":"stop"}\n')
        self.assertEqual(code,0);self.assertTrue(row['stop_requested']);self.assertEqual(len(events),1)

    def test_eof_while_waiting_prevents_launch(self):
        def close(owner,events):self.read_until(owner,events,'entry');owner.stdin.close();owner.stdin=None
        row,_,code=self.run_prelaunch('hot',close);self.assertEqual(code,2);self.assertIn('pipe EOF',row['failure'])

    def test_eof_during_telemetry_prevents_later_ready_launch(self):
        def close(owner,events):self.read_until(owner,events,'sampling');owner.stdin.close();owner.stdin=None
        row,_,code=self.run_prelaunch('slow_ready',close);self.assertEqual(code,2);self.assertIn('pipe EOF',row['failure'])

    def test_signals_before_start_emit_unstarted_terminal(self):
        for sig in [signal.SIGHUP,signal.SIGTERM,signal.SIGINT]:
            def stop(owner,events):self.read_until(owner,events,'entry');owner.send_signal(sig);owner.wait(timeout=3)
            row,_,code=self.run_prelaunch('hot',stop);self.assertEqual(code,2);self.assertIn('owner signal',row['failure'])

    def test_stop_after_staging_still_prevents_provider_start(self):
        def stop(owner,events):
            self.read_until(owner,events,'staged');owner.stdin.write('{"command":"stop"}\n');owner.stdin.flush()
        row,_,code=self.run_prelaunch('staged',stop)
        self.assertEqual(code,0);self.assertTrue(row['root_created']);self.assertTrue(row['stop_requested'])

    def test_lease_applies_before_provider_start(self):
        row,_,code=self.run_prelaunch('hot',lambda owner,events:owner.wait(timeout=3),deadline=1,lease=.06)
        self.assertEqual(code,2);self.assertIn('controller lease',row['failure'])

    def test_initial_frame_retains_coalesced_stop(self):
        read,write=os.pipe()
        with os.fdopen(read,'rb') as control:
            os.write(write,b'{"request":1}\n{"command":"stop"}\n');os.close(write);request,pending=host.initial_request(control)
        self.assertEqual(request,{'request':1});self.assertEqual(pending,b'{"command":"stop"}\n')

if __name__=='__main__':unittest.main()
