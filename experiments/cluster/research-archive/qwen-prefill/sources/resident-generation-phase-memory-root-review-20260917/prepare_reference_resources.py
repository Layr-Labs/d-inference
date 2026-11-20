"""Quiescent 48 GB disk-cache maintenance after the retained reference refusal."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import shlex
import stat
import subprocess
import time

ROOT = Path(__file__).resolve().parent
RESEARCH = ROOT.parent
SOURCE = RESEARCH/'qwen27b-matched-short-cohort-draft-20260916/physical-source/prepare_resources.py'
REFERENCE = RESEARCH/'resident-generation-phase-memory-draft-20260917/Experiment/reference'

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    if sha(SOURCE) != 'f4477ad6d5b0c046c0a8b10978263c35b8d36dce79c3ee8b8a06ddae906907e6':
        raise ValueError('Reviewed maintenance source changed')
    collected = REFERENCE/'physical-collect-1/execution.json'
    if sha(collected) != '92f474770ac0a8880b05e23a9d54954517dcca20cd222a143d180bfac2d06dc9':
        raise ValueError('Failed reference collection changed')
    collection = json.loads(collected.read_bytes())
    terminal = json.loads((REFERENCE/'physical-collect-1/returned/terminal.json').read_bytes())
    if not (collection['passed'] and collection['active'] == [] and collection['journalBytes'] == 0
        and terminal['status'] == 'failed' and terminal['nativeLeaderReaped']
        and terminal['ownedGroupFenceComplete'] and terminal['sourceInputsUnchanged']
        and terminal['cleanupErrors'] == [] and terminal['postflightErrors'] == []):
        raise ValueError('Actual reference cleanup is incomplete')
    spec = importlib.util.spec_from_file_location('qualified_cache_maintenance', SOURCE)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    credential = RESEARCH.parent/'machines/CREDENTIALS.private.md'
    info = credential.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError('Private credential ownership/mode differs')
    rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
        for line in credential.read_text().splitlines() if line.startswith('|')]
    secret = (rows[2][[cell.lower() for cell in rows[0]].index('password')]+'\n').encode()
    output = ROOT/'reference-resource-preparation-1'; output.mkdir(mode=0o700)
    record = dict(passed=False, nativeResourceFloorsChanged=False, host='darkbloom-48',
        maintenanceSourceSHA256=sha(SOURCE), remoteScriptSHA256=hashlib.sha256(module.REMOTE.encode()).hexdigest())
    started = time.monotonic()
    try:
        command = module.SSH+['-S','none','darkbloom-48',shlex.join(['/usr/bin/python3','-B','-c',module.REMOTE])]
        result = subprocess.run(command,input=secret,capture_output=True,timeout=50)
        for name,data in [('stdout',result.stdout),('stderr',result.stderr)]:
            with (output/name).open('xb') as stream: stream.write(data.replace(secret.rstrip(b'\n'),b'[REDACTED]'))
        record['exitCode'] = result.returncode
        if result.returncode or result.stderr or len(result.stdout)>131072:
            raise ValueError('Quiescent cache maintenance failed; evidence retained')
        value = json.loads(result.stdout)
        if not all(value[x] for x in ['passed','journalUnchanged','reaped','groupAbsent']):
            raise ValueError('Maintenance postflight failed')
        if any(v['pressureLevel'] != 1 or v['acPower'] is not True or float(v['reportedSwapBytes']) != 0
            for v in [value['before'],value['after']]): raise ValueError('Resource state differs')
        record.update(passed=True,beforeFreeBytes=value['before']['actualFreeBytes'],
            afterFreeBytes=value['after']['actualFreeBytes'],nativeOrModelExecuted=False)
    finally:
        record['elapsedSeconds'] = time.monotonic()-started
        with (output/'receipt.json').open('x') as stream:
            json.dump(record,stream,indent=2,sort_keys=True);stream.write('\n')
    print(json.dumps(record,sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077);main()
