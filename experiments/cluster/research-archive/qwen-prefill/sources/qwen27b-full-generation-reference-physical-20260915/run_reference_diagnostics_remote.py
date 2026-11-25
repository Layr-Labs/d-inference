from pathlib import Path
import json,os,shlex,signal,subprocess,time
base=Path(__file__).resolve().parent
out=base/'run-2';out.mkdir(mode=0o700)
script='''from pathlib import Path
import json,os,subprocess,sys
root=Path('/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915')
sys.path.insert(0,str(root/'supervisor-diagnostics'));sys.dont_write_bytecode=True
from reference_resources import sample_local,validate_local
ps=subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True)
names={'darkbloom','cluster-inference','darkbloom-cluster-worker','darkbloom-owner-qualification','owner-controller'}
active=[s.strip() for s in ps.splitlines() if len(s.split(maxsplit=1))==2 and Path(s.split(maxsplit=1)[1]).name in names]
assert not active,active
journal=Path('/Users/developer/.darkbloom/cluster-device/native-device.lease');assert journal.is_file() and not journal.is_symlink() and journal.stat().st_size==0
resource=sample_local();validate_local(resource)
print(json.dumps(dict(kind='root_reference_preflight',active=active,journalBytes=0,resource=resource)),flush=True)
os.chdir(root/'supervisor-diagnostics')
os.execv('/usr/bin/python3',['/usr/bin/python3','-B',str(root/'supervisor-diagnostics/run_reference.py'),'--job',str(root/'supervisor-diagnostics/example-job.json'),'--job-sha256','ba3526948eda95468059088b18104dcfad9c2b923dba5078e0bc91b3aff7d639','--launcher-sha256','43c4dcaaef9ec06b51379146606f664fcfebdf5c98aeaf49c0e578183dc9273c'])
'''
(out/'remote-launch.py').write_text(script)
argv=['/usr/bin/ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=8','darkbloom-48','/usr/bin/python3 -B -']
start=time.monotonic();receipt=dict(argv=argv,remoteRun='/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/runs/short-27b-2',timedOut=False,localRunnerPID=os.getpid())
with (out/'ssh.stdout').open('xb') as stdout,(out/'ssh.stderr').open('xb') as stderr:
 child=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=stdout,stderr=stderr,start_new_session=True)
 receipt.update(sshPID=child.pid,sshPGID=child.pid)
 (out/'live.json').write_text(json.dumps(receipt,indent=2)+'\n')
 try:
  child.communicate(input=script.encode(),timeout=420)
 except BaseException as error:
  receipt['error']=type(error).__name__+': '+str(error);receipt['timedOut']=isinstance(error,subprocess.TimeoutExpired)
  if child.returncode is None:
   try:os.killpg(child.pid,signal.SIGKILL)
   except ProcessLookupError:pass
   child.wait(timeout=10)
 finally:
  receipt.update(exitCode=child.returncode,elapsedSeconds=time.monotonic()-start,sshReaped=child.returncode is not None)
  (out/'execution.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt),flush=True)
raise SystemExit(0 if child.returncode==0 and 'error' not in receipt else 1)
