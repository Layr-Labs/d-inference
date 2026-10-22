"""Owned 180-second retained-file diagnostic child; no model or native process."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root=Path(__file__).resolve().parent
paths=[root/x for x in ('stdout','stderr','receipt.json','findings.json')]
assert all(not p.exists() for p in paths)
source=root/'diagnose.py'; before=hashlib.sha256(source.read_bytes()).hexdigest()
started=time.monotonic();killed=False
with paths[0].open('xb') as out,paths[1].open('xb') as err:
    child=subprocess.Popen([sys.executable,'-B',str(source)],stdin=subprocess.DEVNULL,stdout=out,stderr=err,start_new_session=True)
    try: code=child.wait(timeout=180)
    except subprocess.TimeoutExpired:
        killed=True;os.killpg(child.pid,signal.SIGKILL);code=child.wait(timeout=10)
try: os.killpg(child.pid,0);absent=False
except ProcessLookupError: absent=True
after=hashlib.sha256(source.read_bytes()).hexdigest()
receipt=dict(schema='bounded_retained_numerical_diagnostic_child_v1',argv=[sys.executable,'-B',str(source)],
             pid=child.pid,elapsedSeconds=time.monotonic()-started,deadlineSeconds=180,killedOwnedGroup=killed,
             exitCode=code,reaped=True,groupAbsent=absent,sourceSHA256=before,sourceUnchanged=before==after,
             status='completed' if code==0 and absent and not killed and before==after else 'failed',
             noCompilerNativeGPUOrRemoteExecution=True)
for name in ('stdout','stderr','findings.json'):
    p=root/name
    if p.exists(): receipt[name]=dict(bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest())
with paths[2].open('x') as f: json.dump(receipt,f,indent=2);f.write('\n')
print(json.dumps(receipt));sys.exit(0 if receipt['status']=='completed' else 1)
