#!/usr/bin/env python3
"""Root-only read-only SSH postflight after a SHA-pinned successful solo run."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import sys
from solo_prefill_provenance_records import BINARY, require, valid_hash, validate_completion

# The remote command is fixed read-only stdlib code. Exact owned paths are passed
# as JSON in one shell-quoted argument; no payload or user code is executed.
REMOTE = '''import datetime,json,subprocess,sys
layout=json.loads(sys.argv[1]);bundle=layout['bundle'];native=layout['native']
def read(args):
 result=subprocess.run(args,check=True,capture_output=True,text=True,timeout=2)
 if result.stderr or len(result.stdout.encode())>2097152:raise ValueError('Unexpected bounded read output')
 return result.stdout
raw=read(['/bin/ps','-axo','pid=,ppid=,pgid=,rss=,command=']);rows=[]
for line in raw.splitlines():
 parts=line.strip().split(None,4)
 if len(parts)!=5:continue
 command=parts[4];kind=None
 if command==bundle+'/cluster-inference' or command.startswith(bundle+'/cluster-inference '):kind='native'
 elif bundle+'/rank_worker.py' in command.split() and native+'/rank.json' in command.split():kind='supervisor'
 if kind:
  if any(int(value)<0 for value in parts[:4]) or int(parts[0])==0:raise ValueError('Invalid owned process observation')
  rows.append(dict(kind=kind,pid=int(parts[0]),ppid=int(parts[1]),pgid=int(parts[2]),rssBytes=int(parts[3])*1024,command=command))
if len(rows)>16:raise ValueError('Too many matching processes')
print(json.dumps(dict(timestampUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),ownedLiveProcesses=rows,remoteRun=layout['run'],memory=read(['/usr/sbin/sysctl','-n','kern.memorystatus_vm_pressure_level','vm.swapusage']),vmStat=read(['/usr/bin/vm_stat']),hardware=read(['/usr/sbin/sysctl','-n','hw.model','hw.memsize','hw.physicalcpu']),osVersion=read(['/usr/bin/sw_vers']),pythonVersion=sys.version),allow_nan=False))
'''


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 32 * 1024**2, 'Invalid bounded metadata file')
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate metadata key')
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique,
                      parse_constant=lambda _: require(False, 'Nonfinite metadata'))


def cleanup_source_identity(run, receipt):
    require(sha(run / 'source-manifest.json') == receipt['source_manifest_sha256']
            and sha(run / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Cleanup provenance manifest differs')
    source = {x['path']: x for x in read(run / 'source-manifest.json')['files']}
    bundle = {x['path']: x for x in read(run / 'bundle/bundle.json')['files']}
    require(bundle['cluster-inference']['sha256'] == BINARY, 'Unexpected native bundle identity')
    result = {}
    for name in ('rank_worker.py', 'processes.py'):
        relative = 'experiments/cluster/runtime/' + name
        path, entry = run / 'source' / relative, source[relative]
        require(sha(path) == entry['sha256'] and path.stat().st_size == entry['size_bytes'], 'Cleanup source changed')
        result[name] = entry['sha256']
    require(sha(run / 'bundle/rank_worker.py') == bundle['rank_worker.py']['sha256'] == result['rank_worker.py'],
            'Worker cleanup source differs from staged bundle')
    require(sha(run / 'native/rank.json') == receipt['rank_configuration_sha256'], 'Owned rank config changed')
    rank = read(run / 'native/rank.json')
    require(rank['bundle'] == receipt['remote_paths']['bundle'] and rank['rank'] == 0 and rank['persistent'] is False,
            'Owned worker configuration differs')
    return result


def observe(receipt, invoke):
    validate_completion(receipt)
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', receipt['execution_host'],
        shlex.join(['/usr/bin/python3', '-c', REMOTE, json.dumps(receipt['remote_paths'], allow_nan=False)])]
    result = invoke(command, capture_output=True, text=True, timeout=20)
    require(len(result.stdout.encode()) <= 2 * 1024**2 and len(result.stderr.encode()) <= 65536, 'SSH output exceeded bound')
    observation = json.loads(result.stdout) if result.returncode == 0 else None
    if observation is not None:
        require(observation['remoteRun'] == receipt['remote_paths']['run']
                and type(observation['ownedLiveProcesses']) is list, 'Postflight run identity differs')
    return dict(sshExitCode=result.returncode, sshStderr=result.stderr,
        observation=observation, passed=result.returncode == 0 and not result.stderr
            and observation['ownedLiveProcesses'] == [])


def main(argv=None, invoke=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--receipt-sha256', required=True)
    parser.add_argument('--root-launcher-exit-code', type=int, choices=[0], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    valid_hash(args.receipt_sha256)
    run = args.run.resolve(strict=True)
    require(not args.output.exists(), 'Preserve earlier postflight')
    source = run / 'receipt.json'
    require(sha(source) == args.receipt_sha256, 'Completed launcher receipt pin differs')
    receipt = read(source)
    execution = validate_completion(receipt)
    cleanup = cleanup_source_identity(run, receipt)
    script_hash = sha(Path(__file__))
    helper_hash = sha(Path(__file__).with_name('solo_prefill_provenance_records.py'))
    record = dict(kind='root_remote_solo_prefill_postflight', schemaVersion=1,
        timestampUTC=datetime.now(timezone.utc).isoformat(), launcherReceiptSHA256=args.receipt_sha256,
        scriptSHA256=script_hash, helperSHA256=helper_hash, runID=receipt['run_id'], nativeBinarySHA256=BINARY,
        cleanupSourceSHA256=cleanup, rootLauncherTerminalExitCode=args.root_launcher_exit_code,
        remoteReapingIndependentlyProven=False, remoteWorkerCleanupSourceBound=True,
        localSSHClientPID=execution['local_ssh_client_pid'], localSSHClientReaped=True,
        observation=None, passed=False)
    try:
        record.update(observe(receipt, invoke or subprocess.run))
    except Exception as error:
        record['error'] = type(error).__name__ + ': ' + str(error)
    require(sha(source) == args.receipt_sha256 and sha(Path(__file__)) == script_hash
            and sha(Path(__file__).with_name('solo_prefill_provenance_records.py')) == helper_hash,
            'Receipt/postflight source changed while observing')
    with args.output.open('x') as stream:
        json.dump(record, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(passed=record['passed'], output=str(args.output), sha256=sha(args.output))))
    return 0 if record['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
