#!/usr/bin/env python3
"""Saved-evidence-only resource supplement; never executes a process observer."""
import datetime
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import re

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
OUTPUT = ROOT / 'lookahead-resources-supplement-20260914.json'
PINS = {
    'qwen-layer-stage-lookahead-independent-cpu-audit-20260914.json': '697b5656207dfe3decbd75897bc213389119eca9b0c943ff50b14e5a9a727b43',
    'audit-qwen-layer-stage-lookahead-20260914.py': 'a29c4f2f02c0d638b0b24ed023133d68437cc599ed09c25792806ba5e4008808',
    'qwen-layer-stage-lookahead-retry1-resource-screen-20260914.json': '5d1230c15dfd8df75b42006ce765dd2b83886c7dd626e6e488772d0461038678',
    'observe-owned-lookahead-retry1-20260914.py': 'd864b30ea0e3681f370cfcb555b4d0213d4a1dd1f705575edbec0676269bfe6b',
    'qwen-layer-stage-lookahead-retry1-process-observations-20260914.json': 'dc16fc4d8e6bcd4b9f2ec523b30de00d9de7291063b559e3de43896598fca4df',
    'qwen-layer-stage-lookahead-retry1-postflight-20260914.json': 'ba28e45694e701cf03834cca33750e33a7f0bf91b3b82fc9356c71b8109d7464',
    'qwen-layer-stage-lookahead-resource-abort-postflight-20260914.json': '8f4e014f0939bb8d07dc672a8ab0667e494456356a0837e7eec2bf79e90d1080',
    'runs/qwen-layer-stage-lookahead-retry1-20260914/receipt.json': '2979510c083f23963cedabce62cec962d65543d316c02c9e016491813bff7cdb',
    'runs/qwen-layer-stage-lookahead-20260914/receipt.json': 'fe29bb8fa222e54f88a850b449eef928e64d7c58a2e3737c91e488557bc5807e',
}


def require(ok, message):
    if not ok: raise ValueError(message)


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    require(path.stat().st_size <= 2 * 1024**2, 'Saved JSON exceeds supplement bound')
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate saved JSON key')
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique,
        parse_constant=lambda _: require(False, 'Nonfinite saved JSON'))


def integer(value, minimum=0):
    require(type(value) is int and value >= minimum, 'Invalid resource/PID integer')
    return value


def free_bytes(vm):
    size = int(re.search(r'page size of (\d+) bytes', vm)[1])
    pages = int(re.search(r'Pages free:\s+(\d+)\.', vm)[1])
    require(size == 16384, 'Recorded page size changed')
    return pages * size


def swap_bytes(raw):
    match = re.fullmatch(r'([0-9]+)\ntotal = ([0-9.]+)M  used = ([0-9.]+)M  free = ([0-9.]+)M  \(encrypted\)\n', raw)
    require(match is not None and int(match[1]) == 2, 'Recorded swap/pressure syntax differs')
    return Decimal(match[3]) * 1024**2


def saved_swap_samples(launch):
    values = []
    for sample in launch['memory_samples']:
        value = swap_bytes(sample['raw_sysctl'])
        require(value == Decimal(sample['swap_used_bytes']) and sample['pressure_level'] == 2, 'Swap raw/numeric values differ')
        values.append(value)
    require(values, 'No saved swap samples')
    return values


def main():
    require(not OUTPUT.exists(), 'Preserve prior supplemental receipt')
    for name, expected in PINS.items(): require(digest(ROOT / name) == expected, 'Frozen input changed: ' + name)
    audit = read(ROOT / 'qwen-layer-stage-lookahead-independent-cpu-audit-20260914.json')
    launch = read(ROOT / 'runs/qwen-layer-stage-lookahead-retry1-20260914/receipt.json')
    failed = read(ROOT / 'runs/qwen-layer-stage-lookahead-20260914/receipt.json')
    screen = read(ROOT / 'qwen-layer-stage-lookahead-retry1-resource-screen-20260914.json')
    observer = read(ROOT / 'qwen-layer-stage-lookahead-retry1-process-observations-20260914.json')
    post = read(ROOT / 'qwen-layer-stage-lookahead-retry1-postflight-20260914.json')
    failed_post = read(ROOT / 'qwen-layer-stage-lookahead-resource-abort-postflight-20260914.json')
    require(audit['status'] == 'passed' and audit['cpuOnly'] is True and audit['nativeExitCodes'] == [0, 0]
        and audit['auditScriptSHA256'] == PINS['audit-qwen-layer-stage-lookahead-20260914.py']
        and audit['originalLauncherReceiptSHA256'] == PINS['runs/qwen-layer-stage-lookahead-retry1-20260914/receipt.json']
        and audit['savedObserverSHA256'] == PINS['qwen-layer-stage-lookahead-retry1-process-observations-20260914.json']
        and audit['savedPostflightSHA256'] == PINS['qwen-layer-stage-lookahead-retry1-postflight-20260914.json'], 'Completed audit binding differs')
    actual_free = free_bytes(screen['vmStat']); minimum = integer(screen['minimumActualFreeBytes'])
    require(actual_free == screen['actualFreeBytes'] == 7447019520 and minimum == 6 * 1024**3
        and actual_free >= minimum and screen['previousRunPreserved'] is True, 'Retry free-memory screen differs')
    launch_free = free_bytes(launch['preflight']['vm_stat'])
    require(launch['memory_gate'] == failed['memory_gate']
        == 'preflight >=8GiB estimated reclaimable; pressure<=2; zero increase in reported swap'
        and launch['preflight']['required_reclaimable_bytes'] == failed['preflight']['required_reclaimable_bytes'] == 8 * 1024**3
        and launch['preflight']['passed'] is True, 'Retry changed the original launcher resource gate')
    failed_swaps, retry_swaps = saved_swap_samples(failed), saved_swap_samples(launch)
    increment = max(failed_swaps) - failed_swaps[0]
    require(len(failed_swaps) == 10 and increment == 118 * 1024**2
        and failed_swaps[-1] == max(failed_swaps) and len(retry_swaps) == 13
        and all(value == failed_swaps[-1] for value in retry_swaps)
        and swap_bytes(screen['sysctl']) == retry_swaps[0], 'Failed/retry swap history differs')
    require(launch['passed'] is True and launch['cohort']['exit_codes'] == [0, 0]
        and launch['cohort']['supervisors_reaped'] is True and launch['cohort']['cancellation_reason'] is None
        and post['sourceReceiptSHA256'] == PINS['runs/qwen-layer-stage-lookahead-retry1-20260914/receipt.json']
        and post['passed'] is True and post['ownedLiveProcesses'] == [] and post['supervisorsReaped'] is True
        and post['supervisorExitCodes'] == [0, 0] and Decimal(post['additionalReportedSwapBytes']) == 0, 'Successful saved cleanup differs')
    require(failed['passed'] is False and failed['cohort']['exit_codes'] == [143, 143]
        and failed['cohort']['supervisors_reaped'] is True and failed['cohort']['validation'] is None
        and failed['error'] == failed['cohort']['error'] == 'ValueError: New OS-reported swap usage during stage transport check'
        and failed_post['sourceReceiptSHA256'] == PINS['runs/qwen-layer-stage-lookahead-20260914/receipt.json']
        and failed_post['nativeExecutionSucceeded'] is False and failed_post['supervisorExitCodes'] == [143, 143]
        and failed_post['supervisorsReaped'] is True and failed_post['ownedLiveProcesses'] == []
        and failed_post['terminalNativeRecords'] == 0 and failed_post['runPreserved'] is True
        and Decimal(failed_post['additionalReportedSwapBytes']) == increment, 'Original resource abort/cleanup differs')
    failed_ready_files = []
    for rank in range(2):
        relative = f'rank-{rank}/stdout.jsonl'; entry = next(x for x in failed['rank_files'] if x['path'] == relative)
        path = ROOT / 'runs/qwen-layer-stage-lookahead-20260914' / relative
        require(path.stat().st_size == entry['size_bytes'] <= 4096 and digest(path) == entry['sha256'], 'Aborted stdout changed')
        lines = path.read_bytes().splitlines(); require(len(lines) == 1, 'Aborted run gained a terminal record')
        ready = json.loads(lines[0]); require(ready == dict(kind='qwen_layer_stage_lookahead_ready', schemaVersion=1,
            epoch=failed['epoch'], rank=rank, worldSize=2, transport='loopback-test', backend='ring',
            flow='prompt_lookahead_one_v1', envelopeVersion=2), 'Aborted ready identity differs')
        failed_ready_files.append(dict(path=str(path), sha256=entry['sha256'], byteCount=entry['size_bytes']))
    require(observer['observerSHA256'] == PINS['observe-owned-lookahead-retry1-20260914.py']
        and post['processObserverSHA256'] == PINS['qwen-layer-stage-lookahead-retry1-process-observations-20260914.json']
        and observer['nativeRSSMeasurementAvailable'] is True and observer['terminatedOnLauncherFinalReceipt'] is True,
        'Observer source/result binding differs')
    supervisors = set(launch['cohort']['supervisor_pids']); natives = set(observer['observedNativePIDs'])
    require(len(supervisors) == len(natives) == 2 and not supervisors.intersection(natives), 'Recorded owner PID sets differ')
    mapping = {}; supervisor_parents = set(); seen_supervisors = set(); seen_natives = set(); peaks = {}; sums = []
    samples = observer['samples']; last_time = None; native_samples = 0
    require(type(samples) is list and 1 <= len(samples) <= 2000, 'Observer sample bound differs')
    for sample in samples:
        require(set(sample) == {'monotonicSeconds', 'ownedProcesses'} and type(sample['monotonicSeconds']) in (int, float)
            and (last_time is None or sample['monotonicSeconds'] > last_time), 'Observer chronology/schema differs')
        last_time = sample['monotonicSeconds']; rows = sample['ownedProcesses']
        require(type(rows) is list and len(rows) <= 4 and len({p['pid'] for p in rows}) == len(rows), 'Duplicate/excess sampled owner')
        total = 0; has_native = False
        for process in rows:
            require(set(process) == {'pid', 'ppid', 'rssBytes', 'native', 'supervisor'}
                and type(process['native']) is bool and type(process['supervisor']) is bool
                and process['native'] != process['supervisor'], 'Observer process type/classification differs')
            pid, parent, rss = integer(process['pid'], 1), integer(process['ppid'], 1), integer(process['rssBytes'])
            require(rss % 1024 == 0, 'Observer RSS no longer matches ps KiB conversion')
            if process['native']:
                require(pid in natives and parent in supervisors and mapping.get(pid, parent) == parent,
                    'Native PID does not retain its root-owned supervisor parent')
                mapping[pid] = parent; seen_natives.add(pid); peaks[pid] = max(peaks.get(pid, 0), rss)
                total += rss; has_native = True
            else:
                require(pid in supervisors and parent not in supervisors | natives, 'Supervisor PID ancestry differs')
                seen_supervisors.add(pid); supervisor_parents.add(parent)
        native_samples += int(has_native); sums.append(total)
    require(seen_natives == natives and seen_supervisors == supervisors and len(supervisor_parents) == 1
        and set(mapping.values()) == supervisors and samples[0]['ownedProcesses'] == [] and samples[-1]['ownedProcesses'] == [],
        'Observer did not cover both parent-owned natives and clean endpoints')
    peak = max(sums); peak_index = sums.index(peak)
    require(peak == observer['peakObservedSumNativeRSSBytes'] == post['peakObservedSumNativeRSSBytes']
        == audit['resources']['peakObservedSumNativeRSSBytes'] == 5150015488, 'Combined sampled native RSS differs')
    dates = [failed_post['checkedAtUTC'], screen['checkedAtUTC'], observer['observedAtUTC'], post['checkedAtUTC'], audit['auditedAtUTC']]
    require(all(a <= b for a, b in zip([datetime.datetime.fromisoformat(x) for x in dates],
        [datetime.datetime.fromisoformat(x) for x in dates][1:])), 'Saved cleanup/screen/observer/audit chronology differs')
    result = dict(schemaVersion=1, status='passed', cpuOnly=True, auditedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        helperSHA256=digest(Path(__file__)), completedLookaheadAuditSHA256=PINS['qwen-layer-stage-lookahead-independent-cpu-audit-20260914.json'],
        pinnedInputs=[dict(path=str(ROOT / name), sha256=value, byteCount=(ROOT / name).stat().st_size) for name, value in PINS.items()],
        actualFreeScreen=dict(minimumBytes=minimum, screenFreeBytes=actual_free, launchPreflightFreeBytes=launch_free,
            failedLaunchPreflightFreeBytes=free_bytes(failed['preflight']['vm_stat']), freePagesTimesPageSizeIndependentlyRecomputed=True,
            screenMeetsSixGiBThreshold=actual_free >= minimum, launchPreflightMeetsSixGiBThreshold=launch_free >= minimum,
            freeBytesDeclineBetweenScreenAndLaunchPreflight=actual_free - launch_free,
            originalLauncherGate=launch['memory_gate'], originalNoNewSwapGateUnchanged=True),
        observedOwnership=dict(nativePIDToSupervisorPID={str(k): v for k, v in sorted(mapping.items())},
            observedCommonLauncherParentPID=next(iter(supervisor_parents)), supervisorPIDs=sorted(supervisors),
            nativePIDs=sorted(natives), sampleCount=len(samples), samplesWithNativeProcesses=native_samples,
            firstAndLastSavedSamplesEmpty=True, observerSourceReadAndHashedButNotExecuted=True,
            nativeCommandFilter='Exact archived bundle executable path or that path followed by a space.',
            supervisorCommandFilter='rank_worker.py followed by a space, plus this run directory and /rank- in command.'),
        sampledRSS=dict(combinedNativePeakBytes=peak, peakSampleOrdinal=peak_index,
            peakSampleMonotonicSeconds=samples[peak_index]['monotonicSeconds'],
            peakSampleNativeProcesses=[p for p in samples[peak_index]['ownedProcesses'] if p['native']],
            perNativePIDObservedPeaks={str(k): v for k, v in sorted(peaks.items())}, supervisorsExcludedFromNativeRSS=True,
            isTruePeak=False),
        swapHistory=dict(originalAbortAdditionalWholeSystemReportedBytes=str(increment),
            originalAbortExitCodes=[143, 143], originalAbortTerminalRecords=0, originalAbortReadyFiles=failed_ready_files,
            retryStartingReportedSwapBytes=str(retry_swaps[0]), retryAdditionalReportedSwapBytes='0',
            retryExitCodes=[0, 0], bothSavedPostflightsReportNoOwnedLiveProcesses=True, bothSupervisorPairsReaped=True),
        newProcessInventoryCalls=0, newNativeExecutions=0, newModelPayloadReads=0, rewrittenPriorArtifacts=0,
        limitations=['All checks use saved evidence; no current process inventory or model/inference operation was performed.',
            'RSS is the maximum sum of native process samples, not a measured true peak or the sum of separately timed per-PID maxima.',
            'Command classification is bound to the pinned observer source; original ps command lines and process start-generation IDs were not persisted. Parent PIDs are validated within the saved trace against the pinned launcher supervisors.',
            'Whole-system reported swap rose by 118 MiB during the aborted attempt. The retry added no further reported swap; this does not imply zero total swap or attribute all existing swap to this workload.',
            'The separate actual-free screen passed 6 GiB, but saved launcher preflight actual free was 3,379,560,448 bytes and did not meet that threshold. Only the unchanged estimated-reclaimable/pressure/no-new-swap launcher gate was enforced at that later snapshot.',
            'The additional actual-free screen is a snapshot admission check, not a guarantee of future available memory.'])
    for name, expected in PINS.items(): require(digest(ROOT / name) == expected, 'Pinned evidence changed during audit')
    with OUTPUT.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status='passed', output=str(OUTPUT), receiptSHA256=digest(OUTPUT), helperSHA256=digest(Path(__file__)),
        actualFreeBytes=actual_free, combinedSampledNativeRSSBytes=peak, nativePIDToSupervisorPID=mapping,
        originalAbortNewSwapBytes=int(increment), retryNewSwapBytes=0), sort_keys=True))


if __name__ == '__main__': main()
