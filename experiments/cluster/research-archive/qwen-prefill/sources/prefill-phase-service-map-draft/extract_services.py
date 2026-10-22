"""Rebuild the two fixed retained service vectors; never run model/audit helpers.

Default: check all saved input pins and exact derived JSON, print a short receipt.
--emit: perform the same checks, then emit the derived vector JSON to stdout.
No files are written. Source/runtime/numerical qualification remains external.
"""
from hashlib import sha256
from pathlib import Path
import json
import sys

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
SETTINGS = [
    ('balanced_phase', 16, 'qwen-long-prefill-ranks-serial-phase-peer24-20260914',
     'qwen-long-prefill-ranks-serial-phase-sidecars-20260914', 'independent-cpu-audit.json', False),
    ('cut12_phase_owner', 12, 'qwen-long-prefill-ranks-cut12-serial-owner-peer24-20260914',
     'qwen-long-prefill-ranks-cut12-serial-owner-sidecars-peer24-20260914', 'cpu-audit.json', True),
]
MARKERS = {
    'producerPrepareNanoseconds': (0, 'prepare.begin', 'prepare.committed'),
    'producerPreHeaderLocalNanoseconds': (0, 'prepare.committed', 'send.beginHeader'),
    'producerReleaseNanoseconds': (0, 'send.receivedACKAccepted', 'producerBoundaryReleased'),
    'consumerConsumeAndFinalSelectionNanoseconds': (
        1, 'receive.beginConsumption', 'receive.consumptionAndSelectionValidated'),
    'consumerReleaseNanoseconds': (
        1, 'receive.consumptionAndSelectionValidated', 'receive.consumedBoundaryReleased'),
}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def encoded(value):
    return (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n').encode()


def build():
    pin_path = HERE / 'source-and-input-pins.json'
    pin_bytes = pin_path.read_bytes()
    pins = json.loads(pin_bytes)['pins']
    snapshots = {}
    for path, pin in pins.items():
        p = Path(path)
        require(p.is_file() and p.stat().st_size == pin['byteCount'] <= 1_048_576,
                'Pinned regular source/JSON size differs: ' + path)
        raw = p.read_bytes()
        require(len(raw) == pin['byteCount'] and sha256(raw).hexdigest() == pin['sha256'],
                'Pinned bytes differ: ' + path)
        snapshots[path] = raw

    def raw(path):
        return snapshots[str(path)]

    def js(path):
        return json.loads(raw(path))

    cohorts = []
    for label, cut, run_name, side_name, numerical_name, owner in SETTINGS:
        run, side = BASE / 'runs' / run_name, BASE / 'runs' / side_name
        audit, parent, numerical = js(side / 'phase-audit.json'), js(run / 'receipt.json'), js(run / numerical_name)
        require(audit['status'] == numerical['status'] == 'passed' and parent['passed'] is True,
                'Saved qualification status differs')
        reports, traces = [], []
        for rank in range(2):
            sp, tp = Path(audit['inputs'][rank]['path']), Path(audit['inputs'][rank + 2]['path'])
            sb, tb = raw(sp), raw(tp)
            require(sha256(sb).hexdigest() == audit['inputs'][rank]['sha256']
                    and sha256(tb).hexdigest() == audit['inputs'][rank + 2]['sha256'], 'Phase input binding differs')
            rows = [json.loads(line) for line in sb.splitlines()]
            require(len(rows) == 2, 'Two native records required')
            r, t = rows[1], json.loads(tb)
            require(r['kind'] == 'qwen_long_prefill_rank_report' and r['rank'] == rank and r['completed'] is True,
                    'Native report identity differs')
            require(t['clockSource'] == 'DispatchTime.uptimeNanoseconds' and t['identity']['role'] == 'rank' + str(rank)
                    and r['agreement']['schedulingPolicy'] == 'serial_v1', 'Production serial trace required')
            events, actions = t['events'], r['execution']['actions']
            require(len(events) == len(actions) == (204, 235)[rank], 'Action count differs')
            for a, e in zip(actions, events):
                require(a['ordinal'] == e['ordinal'] and a['action'] == e['phase']
                        and a.get('frameSequence') == e.get('frameSequence')
                        and a['nativeCommittedTokens'] == e['committedTokens'], 'Action/phase differs')
                require(type(e['localUptimeNanoseconds']) is int and 0 <= e['localUptimeNanoseconds'] < 2**64,
                        'UInt64 local timestamp required')
            require(all(a['localUptimeNanoseconds'] <= b['localUptimeNanoseconds']
                        for a, b in zip(events, events[1:])), 'Local clock reversed')
            require(t['identity']['requestFingerprint'] == r['agreement']['recordedRequestFingerprint']
                    == numerical['recordedRequestFingerprint'] == audit['ranks'][rank]['recordedRequestFingerprint']
                    and r['agreementFingerprint'] == numerical['agreementFingerprint']
                    == audit['ranks'][rank]['agreementFingerprint'], 'Saved identity join differs')
            reports.append(r)
            traces.append(t)
        require(reports[0]['agreement'] == reports[1]['agreement'], 'Rank agreements differ')
        maps = [{(e['phase'], e.get('frameSequence')): e for e in t['events']} for t in traces]
        require(all(len(m) == len(t['events']) for m, t in zip(maps, traces)), 'Duplicate phase/frame')
        frames = []
        for i in range(16):
            frame = reports[0]['execution']['frames'][i]['commit']['frame']
            require(frame == reports[1]['execution']['frames'][i]['commit']['frame']
                    == dict(sequence=i, phase='prefill', tokenOffset=i*512, tokenCount=512, finalPromptChunk=i == 15),
                    'Exact fixed frame geometry differs')
            envelope = json.loads(reports[0]['execution']['frames'][i]['exactEnvelopeJSON'])
            require(envelope['boundary']['byteCount'] == 4_194_304, 'Boundary logical size differs')
            item = dict(frameSequence=i, tokenOffset=i*512, tokenCount=512,
                        committedTokens=(i+1)*512, boundaryLogicalBytes=4_194_304)
            for key, (rank, start, end) in MARKERS.items():
                a, b = maps[rank][start, i], maps[rank][end, i]
                require(b['ordinal'] == a['ordinal'] + 1, 'Adjacent serial markers required')
                item[key] = b['localUptimeNanoseconds'] - a['localUptimeNanoseconds']
            for rank, key, name in [
                (0, 'producerPrepareNanoseconds', 'stage0_prepare_cpu_observed'),
                (1, 'consumerConsumeAndFinalSelectionNanoseconds', 'stage1_consume_and_final_selection_cpu_observed'),
            ]:
                group = next(g for g in audit['ranks'][rank]['intervalGroups'] if g['name'] == name)
                require(group['intervals'][i]['frameSequence'] == i
                        and group['intervals'][i]['elapsedNanoseconds'] == item[key], 'Saved audited service differs')
            frames.append(item)
        if cut == 12:
            join = js(side / 'qualification-join.json')
            require(join['passed'] is True and join['stage_cut'] == 12 and join['physical_two_machine_execution'] is False
                    and join['parent_sha256'] == pins[str(run / 'receipt.json')]['sha256']
                    and join['numerical_audit_sha256'] == pins[str(run / numerical_name)]['sha256']
                    and join['phase_audit_sha256'] == pins[str(side / 'phase-audit.json')]['sha256'], 'Cut12 saved join differs')
        a = reports[0]['agreement']
        identity_keys = ['planFingerprint', 'artifactAggregateSHA256', 'sourceConfigurationSHA256',
                         'recordedRequestFingerprint', 'epoch', 'profile', 'profileFingerprint',
                         'arithmeticEnvironmentSHA256', 'promptTokenIDsSHA256', 'producerStageFingerprint',
                         'consumerStageFingerprint', 'producerConstructionConfigurationSHA256',
                         'consumerConstructionConfigurationSHA256']
        cohorts.append(dict(
            label=label, sourceLayerRanges=[[0, cut], [cut, 32]], **{k: a[k] for k in identity_keys},
            agreementFingerprint=reports[0]['agreementFingerprint'], promptFileSHA256=reports[0]['promptFileSHA256'],
            observedSchedulingPolicy='serial_v1', executionHost=parent['execution_host'], observedRankCount=2,
            physicalTwoMachineExecution=False,
            sharedGPUPlacementSource='saved parent execution_host plus public M4 Pro cohort description; not inferred from clocks',
            ownerFrame7InstrumentationEnabled=owner, nativeSHA256=parent['expected_native_sha256'],
            rank0ObservedFirstTokenElapsedNanoseconds=reports[0]['execution']['timing']['elapsedNanoseconds'],
            phaseAuditPath=str(side / 'phase-audit.json'), parentPath=str(run / 'receipt.json'),
            numericalAuditPath=str(run / numerical_name),
            rankStdoutPaths=[v['path'] for v in audit['inputs'][:2]],
            rankPhasePaths=[v['path'] for v in audit['inputs'][2:]], frames=frames,
            serviceTotalsNanoseconds={k: sum(f[k] for f in frames) for k in MARKERS},
        ))
    result = dict(
        kind='retained_local_service_vector_extract', planningInputOnly=True, nativeOrModelExecutionPerformed=False,
        frozenNumericalAuditorsExecuted=False, crossProcessTimestampsCompared=False, gpuKernelTimesMeasured=False,
        targetDeviceTransferabilityVerified=False, networkOrTBLatencyMeasured=False, statisticalConfidenceBoundsEstimated=False,
        markers={k: dict(role='rank' + str(r), startPhase=a, endPhase=b) for k, (r, a, b) in MARKERS.items()},
        optionalPreHeaderGapAdmission='serial_v1 only, adjacent same-frame markers; not portable from lookahead traces',
        cohorts=cohorts,
    )
    require(pin_path.read_bytes() == pin_bytes and all(Path(p).read_bytes() == b for p, b in snapshots.items()),
            'Pinned input changed during extraction')
    return result


if __name__ == '__main__':
    require(sys.argv[1:] in ([], ['--emit']), 'Usage: extract_services.py [--emit]')
    result = build()
    data = encoded(result)
    require(data == (HERE / 'service-vectors.json').read_bytes(), 'Frozen derived vector differs')
    if sys.argv[1:] == ['--emit']:
        sys.stdout.buffer.write(data)
    else:
        print(json.dumps(dict(kind='retained_service_extraction_check', passed=True,
                              vectorSHA256=sha256(data).hexdigest(), cohorts=2, frames=32,
                              primaryLocalServices=64, optionalLocalSpans=96,
                              nativeOrModelExecutionPerformed=False), sort_keys=True))
