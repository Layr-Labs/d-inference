#!/usr/bin/env python3
"""Root-only read-only remote process/resource check after a completed cohort."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

REMOTE = '''import datetime,json,subprocess,sys
layout=json.loads(sys.argv[1]);bundle=layout['bundle'];dirs=layout['rank_directories']
result=subprocess.run(['/bin/ps','-axo','pid=,ppid=,pgid=,rss=,command='],check=True,capture_output=True,text=True,timeout=2)
rows=[]
for line in result.stdout.splitlines():
 parts=line.strip().split(None,4)
 if len(parts)!=5:continue
 command=parts[4];kind=None;rank=None
 if command==bundle+'/cluster-inference' or command.startswith(bundle+'/cluster-inference '):
  kind='native';matches=[i for i,d in enumerate(dirs)if d+'/prompt.json' in command.split()]
  rank=matches[0]if len(matches)==1 else None
 elif bundle+'/rank_worker.py' in command.split():
  kind='supervisor';matches=[i for i,d in enumerate(dirs)if d+'/rank.json' in command.split()]
  rank=matches[0]if len(matches)==1 else None
 if kind:rows.append(dict(kind=kind,rank=rank,pid=int(parts[0]),ppid=int(parts[1]),pgid=int(parts[2]),rssBytes=int(parts[3])*1024,command=command))
def read(args):return subprocess.run(args,check=True,capture_output=True,text=True,timeout=2).stdout
print(json.dumps(dict(timestampUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),ownedLiveProcesses=rows,remoteRun=layout['run'],memory=read(['/usr/sbin/sysctl','-n','kern.memorystatus_vm_pressure_level','vm.swapusage']),vmStat=read(['/usr/bin/vm_stat']),hardware=read(['/usr/sbin/sysctl','-n','hw.model','hw.memsize','hw.physicalcpu']),osVersion=read(['/usr/bin/sw_vers']),pythonVersion=sys.version)))
'''


def main():
    run, output = map(Path, sys.argv[1:])
    assert not output.exists(), 'Preserve previous postflight'
    source = run / 'receipt.json'; data = source.read_bytes(); receipt = json.loads(data)
    assert receipt['kind'] == 'remote_qwen_layer_stage_prefill_rank_launcher'
    assert receipt['passed'] and receipt['cohort']['passed'] and receipt['cohort']['exit_codes'] == [0, 0]
    host = receipt['execution_host']; assert re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', host)
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', host,
               shlex.join(['/usr/bin/python3', '-c', REMOTE, json.dumps(receipt['remote_paths'])])]
    result = subprocess.run(command, capture_output=True, text=True, timeout=20)
    record = dict(kind='root_remote_prefill_rank_postflight', schemaVersion=1,
        timestampUTC=datetime.now(timezone.utc).isoformat(), launcherReceiptSHA256=hashlib.sha256(data).hexdigest(),
        scriptSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        epoch=receipt['epoch'], policy=receipt['stage_prefill_policy'], rootLauncherTerminalExitCode=0,
        sshExitCode=result.returncode, sshStderr=result.stderr, remoteReapingIndependentlyProven=False,
        remoteWorkerCleanupSourceBound=True, localSSHClientPIDs=receipt['cohort']['local_ssh_client_pids'],
        localSSHClientsReaped=receipt['cohort']['local_ssh_clients_reaped'], observation=None, passed=False)
    if result.returncode == 0:
        record['observation'] = json.loads(result.stdout)
        record['passed'] = not result.stderr and not record['observation']['ownedLiveProcesses']
    else:
        record['sshStdout'] = result.stdout
    assert source.read_bytes() == data, 'Launcher receipt changed during postflight'
    with output.open('x') as stream:
        json.dump(record, stream, indent=2, sort_keys=True); stream.write('\n')
    print(json.dumps(dict(passed=record['passed'], path=str(output),
        sha256=hashlib.sha256(output.read_bytes()).hexdigest(), observation=record['observation'])))
    return 0 if record['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
