"""Same qualified quiescent disk-cache preparation before each diagnostic pair."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import time

ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'qwen27b-matched-short-cohort-draft-20260916/physical-source/prepare_resources.py'

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--case',choices=['serial','lookahead'],required=True)
    case=parser.parse_args().case
    if sha(SOURCE)!='f4477ad6d5b0c046c0a8b10978263c35b8d36dce79c3ee8b8a06ddae906907e6':
        raise ValueError('Reviewed resource helper changed')
    for rank in [0,1]:
        if json.loads((ROOT/(case+'-copy'+str(rank)+'-1/receipt.json')).read_bytes())['status']!='passed':
            raise ValueError('Actual completed copies required')
    if case=='lookahead' and json.loads((ROOT/'serial-validate-1/receipt.json').read_bytes())['status']!='passed':
        raise ValueError('Prior serial run must qualify and retire')
    spec=importlib.util.spec_from_file_location('qualified_quiescent_resources',SOURCE)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    credential=ROOT.parent.parent/'machines/CREDENTIALS.private.md';info=credential.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)!=0o600:
        raise ValueError('Credential ownership/mode differs')
    rows=[[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
        for line in credential.read_text().splitlines() if line.startswith('|')]
    secret=(rows[2][[cell.lower() for cell in rows[0]].index('password')]+'\n').encode()
    output=ROOT/(case+'-resource-evidence-1');output.mkdir(mode=0o700)
    for rank,host in enumerate(['darkbloom-24','darkbloom-48']):
        record=dict(passed=False,host=host,nativeResourceFloorsChanged=False,sourceSHA256=sha(SOURCE),
            remoteScriptSHA256=hashlib.sha256(module.REMOTE.encode()).hexdigest())
        start=time.monotonic()
        try:
            command=module.SSH+['-S','none',host,shlex.join(['/usr/bin/python3','-B','-c',module.REMOTE])]
            result=subprocess.run(command,input=secret,capture_output=True,timeout=50)
            for name,data in [('stdout',result.stdout),('stderr',result.stderr)]:
                with (output/(str(rank)+'.'+name)).open('xb') as stream:
                    stream.write(data.replace(secret.rstrip(b'\n'),b'[REDACTED]'))
            record['exitCode']=result.returncode
            if result.returncode or result.stderr or len(result.stdout)>131072:
                raise ValueError('Quiescent resource preparation failed')
            value=json.loads(result.stdout)
            if not all(value[k] for k in ['passed','journalUnchanged','reaped','groupAbsent']):
                raise ValueError('Preparation cleanup failed')
            for observed in [value['before'],value['after']]:
                if observed['pressureLevel']!=1 or observed['acPower'] is not True or float(observed['reportedSwapBytes'])!=0:
                    raise ValueError('Physical resource conditions differ')
            record.update(passed=True,beforeFreeBytes=value['before']['actualFreeBytes'],
                afterFreeBytes=value['after']['actualFreeBytes'],nativeOrModelExecuted=False)
        finally:
            record['elapsedSeconds']=time.monotonic()-start
            with (output/(str(rank)+'.receipt.json')).open('x') as stream:
                json.dump(record,stream,indent=2,sort_keys=True);stream.write('\n')
        print(json.dumps(record,sort_keys=True))

if __name__=='__main__':
    os.umask(0o077);main()
