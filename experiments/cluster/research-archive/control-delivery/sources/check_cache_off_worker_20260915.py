import hashlib
import json
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parent
build=root/'resident-cache-off-build-20260915'
records=build/'records'
binary=build/'workspace/experiments/cluster/inference/.build/arm64-apple-macosx/release/cluster-inference'
previous=root/'resident-aligned-read-build-20260915/records'
pin=json.loads((records/'build-1.json').read_bytes())['nativeSHA256']
assert hashlib.sha256(binary.read_bytes()).hexdigest()==pin
checks=[]
for name,mode in [('worker','qwen-resident-benchmark-worker-check'),('adapter','adapter-check')]:
    result=subprocess.run([str(binary),'--mode',mode],capture_output=True,timeout=45)
    (records/(name+'-check.stdout.jsonl')).write_bytes(result.stdout)
    (records/(name+'-check.stderr.log')).write_bytes(result.stderr)
    lines=result.stdout.splitlines(keepends=True)
    prior=(previous/(name+'-check.stdout.jsonl')).read_bytes().splitlines(keepends=True)
    new=[]
    retained=[line for line in lines if line not in new]
    item=dict(mode=mode,nativeExitCode=result.returncode,stderrBytes=len(result.stderr),
              records=len(lines),priorRecordsByteIdentical=retained==prior,
              newAlignedReadRecords=len(new),stdoutSHA256=hashlib.sha256(result.stdout).hexdigest())
    checks.append(item)
    (records/'cpu-checks.json').write_text(json.dumps(dict(nativeSHA256=pin,modelExecution=False,checks=checks),indent=2)+'\n')
    print(json.dumps(item),flush=True)
    assert result.returncode==0 and not result.stderr and retained==prior
    assert len(new)==0
    if new:
        value=json.loads(new[0]);assert len(value['accepted'])==9 and len(value['rejected'])==10
