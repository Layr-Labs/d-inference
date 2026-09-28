"""Local retained-evidence audit only. No subprocesses, remote calls, or native execution.

Replays raw OS arithmetic independently; reuses the hash-bound closed native
catalog decoder only for the native operation/geometry contract. Large native
payloads are not rehashed here: their before/after physical binding is retained
in every input and terminal receipt. This does not establish a serving profile.
"""
import base64
from decimal import Decimal
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import stat
import sys

sys.dont_write_bytecode = True
ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
BASE = ROOT/'collective-native-allocation-bound-supervisor-48-20260916'
OUT = ROOT/'collective-native-allocation-root-review-20260916/physical-48-review.json'
MANIFEST = 'c0279a736080d88209456a3b22db88fb71bdac63457b23ad1d51f0f22de27577'
NATIVE = '4f4149c7330d8268ac7294ef7b225db25078d2fb853cb06af1d02e73ae66b26c'
REMOTE = '/Users/developer/DarkbloomDev/collective-native-allocation-check-48-20260916'
EMPTY = hashlib.sha256(b'').hexdigest()


def require(condition, detail):
    if not condition:
        raise ValueError(detail)


def encode(value):
    return json.dumps(value, sort_keys=True, allow_nan=False, separators=(',', ':'))


def same(actual, expected, detail):
    require(encode(actual) == encode(expected), detail)


def integer(value, minimum, maximum, detail):
    require(type(value) is int and minimum <= value <= maximum, detail)
    return value


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def read(path, cap=1_048_576):
    require(path.parent.resolve() == path.parent, 'linked evidence parent: '+str(path))
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= cap, 'evidence file bound')
        blocks = []
        remaining = before.st_size
        while remaining:
            block = os.read(fd, min(65_536, remaining))
            require(bool(block), 'truncated evidence')
            blocks.append(block)
            remaining -= len(block)
        require(not os.read(fd, 1), 'evidence grew')
        stamp = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        require(stamp(before) == stamp(os.fstat(fd)) == stamp(path.lstat()), 'evidence changed')
        return b''.join(blocks)
    finally:
        os.close(fd)


def parse(raw):
    def pairs(items):
        out = {}
        for key, value in items:
            require(key not in out, 'duplicate JSON key')
            out[key] = value
        return out
    def invalid(value):
        raise ValueError('nonfinite JSON: '+value)
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)


def value(path):
    return parse(read(path))


def process(record):
    same(record['command'], ['/bin/ps', '-Aww', '-o', 'pid=,uid=,comm='], 'process observation command')
    same(record['prohibited'], [], 'live prohibited process')
    integer(record['observerPID'], 1, 2**31-1, 'observer PID')
    integer(record['processCount'], 1, 100_000, 'process count')
    start = integer(record['observedStartMonotonicNS'], 0, 2**63-1, 'process start')
    end = integer(record['observedEndMonotonicNS'], start, start+3*10**9, 'bounded process observation')
    require(re.fullmatch('[0-9a-f]{64}', record['stdoutSHA256']) is not None, 'process output digest')


def journal(record, original=None):
    same(record['path'], '/Users/developer/.darkbloom/cluster-device/native-device.lease', 'canonical journal path')
    for key in ('directoryDevice', 'directoryInode', 'fileDevice', 'fileInode'):
        integer(record[key], 1, 2**63-1, 'journal identity '+key)
    same(record['bytes'], 0, 'journal not empty')
    same(record['sha256'], EMPTY, 'journal digest')
    same(record['exclusiveObservationLockAcquired'], True, 'journal exclusive observation')
    same(record['journalMutationPerformed'], False, 'journal mutation')
    if original is not None:
        same(record, original, 'same canonical journal identity across observations')


def main():
    require(not OUT.exists(), 'create-only review already exists')
    manifest_raw = read(BASE/'manifest.json')
    same(digest(manifest_raw), MANIFEST, 'bound supervisor manifest')
    manifest = parse(manifest_raw)
    pins = {r['path']: r for r in manifest['files']}
    require(len(pins) == len(manifest['files']) == 32, 'bound manifest membership')
    small_count = 0
    for name, row in pins.items():
        path = BASE/name
        require(path.resolve() == path and path.is_file(), 'bound member path')
        same(path.stat().st_size, row['bytes'], 'bound member size '+name)
        if row['bytes'] <= 1_048_576:
            same(digest(read(path)), row['sha256'], 'bound member digest '+name)
            small_count += 1
    same(small_count, 30, 'small bound member count')
    same(pins['package/bundle/CollectiveAllocationCheck']['sha256'], NATIVE, 'bound native')
    package_raw = read(BASE/'package/package.json')
    package = parse(package_raw)
    package_sha = digest(package_raw)
    for row in package['files']:
        same(pins['package/'+row['path']], dict(row, path='package/'+row['path']), 'package membership')
    schedule = value(BASE/'package/PROBE-SCHEDULE.json')
    same(digest(read(BASE/'package/PROBE-SCHEDULE.json')), '239c9e689d65ba43a1a4824e0bca8d75f0c9bf79e4706b1212ed9998071a9e4e', 'fixed schedule')
    case_ids = [case['id'] for case in schedule['cases']]
    old = value(ROOT/'collective-native-allocation-root-review-20260916/physical-24-review.json')
    same(case_ids, [case['caseID'] for case in old['cases']], 'same 35-case schedule and order')
    same(len(set(case_ids)), 35, 'distinct fixed cases')
    compiled = value(BASE/'package/native-contract/cases.stdout')
    same(compiled, [dict(id=c['id'], byteCounts=[g['bytes'] for g in c['geometries']],
        primingByteCounts=[g['bytes'] for g in c['priming']], failure=c['failure'], rounds=c['rounds'])
        for c in schedule['cases']], 'compiled catalog matches fixed schedule')
    artifact = value(BASE/'package/native-binding.json')
    sys.path.insert(0, str(BASE/'package'))
    from allocation_result import validate_result
    expected_files = set('host.json input-binding.json journal-preflight.json journal-postflight.json owner.json processes-preflight.json processes-postflight.json resources.jsonl terminal.json native/worker-0.stdin native/worker-0.stdout native/worker-0.stderr'.split())
    for prefix in ('physical-run-', 'physical-collect-'):
        same(sorted(p.name for p in BASE.glob(prefix+'*') if p.is_dir()),
             sorted(prefix+c+'-1' for c in case_ids), 'exact complete case directory set')
    first_journal = None
    first_host = None
    cases = []
    count_bytes = 0
    for case_id in case_ids:
        collect = BASE/('physical-collect-'+case_id+'-1')
        run = BASE/('physical-run-'+case_id+'-1')
        for directory, timeout in ((run, 135), (collect, 45)):
            receipt = value(directory/'ssh.execution.json')
            same(receipt['exitCode'], 0, case_id+' SSH exit')
            same(receipt['failure'], None, case_id+' SSH failure')
            require(type(receipt['elapsedSeconds']) in (int, float) and math.isfinite(receipt['elapsedSeconds'])
                    and 0 < receipt['elapsedSeconds'] < timeout, 'bounded SSH elapsed')
            for stream in ('stdout', 'stderr'):
                raw = read(directory/('ssh.'+stream), 12*1_048_576)
                same(digest(raw), receipt[stream+'SHA256'], 'SSH stream hash')
                if stream == 'stderr' or directory == run:
                    same(raw.decode(), '', 'empty SSH stream')
            launched = value(directory/'ssh.launched.json')
            same(launched['timeoutSeconds'], timeout, 'SSH timeout')
            argv = launched['argv']
            same(argv[:-1], ['/usr/bin/ssh','-S','none','-T','-F','/dev/null','-i',
                '/Users/developer/.ssh/id_ed25519_darkbloom_dev','-o','IdentitiesOnly=yes','-o','BatchMode=yes',
                '-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(ROOT/'owner-ssh-preflight-20260915/known_hosts'),
                '-o','GlobalKnownHostsFile=/dev/null','-o','ConnectTimeout=5','-o','ConnectionAttempts=1',
                '-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2','developer@192.0.2.223'], 'SSH identity/options')
            if directory == run:
                same(shlex.split(argv[-1]), ['/usr/bin/env','-i','PATH=/usr/bin:/bin:/usr/sbin:/sbin',
                    'HOME=/Users/gaj','LANG=C','PYTHONNOUSERSITE=1','/usr/bin/python3','-B',REMOTE+'/run_target.py',
                    '--package-sha256',package_sha,'--fixture',case_id,'--attempt','1'], 'exact run command')
            else:
                same(shlex.split(argv[-1]), ['/usr/bin/python3','-B','-c',read(BASE/'collect_remote.py').decode(),case_id,'1'], 'exact collection source')
        transmitted = parse(read(collect/'ssh.stdout', 12*1_048_576))
        same(transmitted['nativeLaunched'], False, 'collection launched no native')
        collection = value(collect/'collection.json')
        same(collection, {k:v for k,v in transmitted.items() if k != 'nativeLaunched' and k != 'files'} | {
            'files': {name: {k:v for k,v in entry.items() if k != 'base64'} for name,entry in transmitted['files'].items()}}, 'collection exact SSH response')
        same(sorted(collection['files']), sorted(expected_files), 'collection closure')
        returned = collect/'returned'
        paths = list(returned.rglob('*'))
        require(not any(p.is_symlink() for p in paths), 'returned symlink')
        same(sorted(str(p.relative_to(returned)) for p in paths if p.is_file()), sorted(expected_files), 'returned closure')
        raw_files = {}
        for name in expected_files:
            raw = read(returned/name)
            same(collection['files'][name], dict(bytes=len(raw), sha256=digest(raw)), 'returned byte/hash '+name)
            require(base64.b64decode(transmitted['files'][name]['base64'], validate=True) == raw, 'wire/returned byte mismatch')
            raw_files[name] = raw
            count_bytes += len(raw)
        local = lambda name: parse(raw_files[name])
        host, binding, terminal, owner = [local(n+'.json') for n in ('host','input-binding','terminal','owner')]
        same(host['physicalMemoryBytes'], 48*1024**3, '48 GiB target')
        same(host['pageSizeBytes'], 16_384, '16 KiB page size')
        same(host['expectedSSHTarget'], 'developer@192.0.2.223', 'target identity')
        same(host['machine'], 'arm64', 'native architecture')
        same(host['uid'], 501, 'host uid')
        if first_host is None: first_host = host
        same(host, first_host, 'stable host identity across catalog')
        same(binding, dict(bundleSHA256=artifact['bundleSHA256'], compiledCatalogSHA256=pins['package/native-contract/cases.stdout']['sha256'],
            fixture=case_id, metallibSHA256=artifact['metallibSHA256'], nativeSHA256=NATIVE,
            packageBytes=sum(r['bytes'] for r in package['files']), packageMembers=len(package['files']),
            packageSHA256=package_sha, resourceProfileQualified=False, sourceSnapshotSHA256=artifact['sourceSnapshotSHA256']), 'exact input/source binding')
        stdout = raw_files['native/worker-0.stdout']
        require(stdout.endswith(b'\n') and stdout.count(b'\n') == 1, 'complete native JSONL')
        require(not raw_files['native/worker-0.stderr'] and not raw_files['native/worker-0.stdin'], 'empty native stderr/stdin')
        report = validate_result(stdout[:-1], case_id, host)
        same(terminal['nativeResult'], report, 'terminal exact native report')
        for key,wanted in dict(schema='collective_allocation_native_observation_v1', fixture=case_id, status='completed',
            primaryFailure=None, postflightErrors=[], cleanupErrors=[], nativeExitCodes=[0]).items():
            same(terminal[key], wanted, 'terminal '+key)
        for key in 'nativeLeaderReaped ownedGroupsAbsent outputComplete sourceInputsUnchanged journalEmptyAfterExit processInventoryClear nativeAllocationExecutionObserved'.split():
            same(terminal[key], True, key)
        for key in 'watchdogExpired fabricatedTargetWeights modelTrunkExecutionObserved registeredCheckpointExecution bilateralVerification windowStateExecutionObserved sharedTargetTransactionObserved registeredProfileExecution throughputMeasurementValid protocolOwnerLeaseReleaseObserved journalMutationPerformed rdmaExecutionObserved protectedServingEnabled'.split():
            same(terminal[key], False, key)
        require(type(terminal['elapsedSeconds']) in (int,float) and 0 < terminal['elapsedSeconds'] < 90, 'parent absolute lifetime')
        same(len(owner['nativePIDs']), 1, 'one native process')
        pid = integer(owner['nativePIDs'][0], 1, 2**31-1, 'native PID')
        same(owner['nativePGIDs'], [pid], 'native own group')
        same(terminal['nativePIDs'], [pid], 'terminal PID')
        same(terminal['owned_group_observation'], [dict(ownedPID=pid,ownedPGID=pid,absent=True)], 'post-reap group absence')
        same(owner['nativeArgv'], [REMOTE+'/bundle/CollectiveAllocationCheck','run-resource-case',case_id], 'native command')
        same(owner['nativeEnvironment'], dict(HOME='/Users/gaj',LANG='C',PATH='/usr/bin:/bin:/usr/sbin:/sbin'), 'native environment')
        same(owner['nativeAlarmSeconds'], 60, 'native lifetime')
        integer(owner['remainingGroupWatchdogSeconds'], 61, 90, 'owned watchdog lifetime')
        same(terminal['retained_streams'], [dict(worker=0,stream=s,path=REMOTE+'/runs/'+case_id+'-1/native/worker-0.'+s,
            bytes=len(raw_files['native/worker-0.'+s]),sha256=digest(raw_files['native/worker-0.'+s]))
            for s in ('stderr','stdin','stdout')], 'retained streams')
        before, after = local('journal-preflight.json'), local('journal-postflight.json')
        journal(before, first_journal)
        if first_journal is None: first_journal = before
        journal(after, first_journal)
        journal(collection['journal'], first_journal)
        for p in (local('processes-preflight.json'), local('processes-postflight.json'), collection['processes']): process(p)
        same(terminal['postflight'], dict(journal=after, processObservation=local('processes-postflight.json')), 'postflight exact observations')
        rows = [parse(line) for line in raw_files['resources.jsonl'].splitlines()]
        require(2 <= len(rows) <= 2000 and rows[0]['phase']=='prelaunch' and rows[-1]['phase']=='postflight', 'resource coverage')
        previous = 0
        minimum = 48*1024**3
        for row in rows:
            start = integer(row['startedMonotonicNS'], previous, 2**63-1, 'resource monotonic order')
            previous = integer(row['completedMonotonicNS'], start, start+10*10**9, 'bounded resource sample')
            pages = re.search(r'page size of (\d+) bytes', row['rawVMStat'])
            free = re.search(r'^Pages free:\s+(\d+)\.', row['rawVMStat'], re.MULTILINE)
            swap = re.search(r'used\s*=\s*([0-9.]+)([MG])', row['rawMemory'])
            require(pages and free and swap, 'raw OS parse')
            same(int(pages[1]), 16_384, 'raw OS page size')
            actual_free = int(pages[1])*int(free[1])
            same(row['actualFreeBytes'], actual_free, 'independent actual-free arithmetic')
            integer(actual_free, 6*1024**3, 48*1024**3, 'actual-free floor')
            same(row['rawMemory'].splitlines()[0], '1', 'raw pressure normal')
            same(row['pressureLevel'], 1, 'pressure normal')
            swap_bytes = Decimal(swap[1])*(1024**2 if swap[2]=='M' else 1024**3)
            require(swap_bytes == 0, 'raw zero swap')
            same(row['reportedSwapBytes'], str(swap_bytes), 'raw swap replay')
            require("Now drawing from 'AC Power'" in row['rawPower'], 'raw AC power')
            same(row['acPower'], True, 'AC power')
            minimum = min(minimum, actual_free)
        require(previous-rows[0]['startedMonotonicNS'] < 90*10**9, 'resource original budget')
        native_peak = report['observedPeakNativeActiveBytes']-report['baselineNativeActiveBytes']
        physical_peak = max(0, report['finalPhysical']['lifetimeMaximumBytes']-report['baselinePhysical']['currentBytes'])
        same(report['conservativeObservedPhysicalIncrementBytes'], physical_peak, 'independent physical increment')
        qualification = dict(caseID=case_id,passed=True,actualNativeCleanup=True,standaloneGateCleanup=True,
            resourceSamples=len(rows),minimumActualFreeBytes=minimum,nativePeakIncrementBytes=native_peak,
            physicalPeakIncrementBytes=physical_peak,rdmaMeasured=False,modelExecuted=False,protectedServingEnabled=False,profileQualified=False)
        same(value(collect/'qualification.json'), qualification, 'qualification independently reconstructed')
        cases.append(dict(caseID=case_id,collectionSHA256=digest(read(collect/'collection.json')),
            elapsedNanoseconds=report['elapsedNanoseconds'],minimumActualFreeBytes=minimum,nativePID=pid,
            nativePeakIncrementBytes=native_peak,physicalPeakIncrementBytes=physical_peak,
            qualificationSHA256=digest(read(collect/'qualification.json')),resourceSamples=len(rows),
            stdoutSHA256=digest(stdout),terminalSHA256=digest(raw_files['terminal.json'])))
    same(len(set(c['nativePID'] for c in cases)), 35, 'distinct fresh native PIDs')
    result = dict(actualCases=35,allNativeProcessesReaped=True,allOwnedGroupsAbsent=True,boundSupervisorSHA256=MANIFEST,
        cases=cases,distinctNativeProcesses=35,maximumNativePeakIncrementBytes=max(c['nativePeakIncrementBytes'] for c in cases),
        maximumPhysicalPeakIncrementBytes=max(c['physicalPeakIncrementBytes'] for c in cases),
        minimumActualFreeBytes=min(c['minimumActualFreeBytes'] for c in cases),nativeSHA256=NATIVE,passed=True,
        profileQualified=False,rdmaMeasured=False,resourceSamples=sum(c['resourceSamples'] for c in cases),
        sameEmptyCanonicalJournal=True,scope='Both codec endpoints plus native staging in one process on the 48 GiB M4 Pro; in-memory ciphertext mailbox',servingEnabled=False)
    same(sorted(result), sorted(old), 'same aggregate schema as 24 GiB review')
    for case in cases: same(sorted(case), sorted(old['cases'][0]), 'same per-case aggregate schema')
    with OUT.open('x') as stream:
        stream.write(json.dumps(result,sort_keys=True,indent=2,allow_nan=False)+'\n')
    print(json.dumps(dict(path=str(OUT),sha256=digest(read(OUT)),returnedFiles=35*12,returnedBytes=count_bytes,
        smallManifestMembersVerified=small_count,**{k:v for k,v in result.items() if k not in ('cases','scope')}),sort_keys=True))


if __name__ == '__main__':
    main()
