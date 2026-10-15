"""Read only the retained v7 decode evidence; create new audit outputs once."""
import hashlib
import json
import math
from pathlib import Path
import statistics

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920')
OUT = Path(__file__).resolve().parent
SERIAL = ROOT / 'cases/p4096-cut7-c64-serial-v7'
OVERLAP = ROOT / 'cases/p4096-cut7-c64-overlap-v7'
RUNTIME = ROOT / 'build/workspace/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
PHASES = ['graphConstruction', 'rootStaging', 'evaluation', 'validationCommit']
CATEGORIES = ['logicalGuard', 'entryGuard', 'ownerGuard', 'environmentGuard', 'osSnapshot',
              'nativeSnapshot', 'outerNativeFault', 'wireSendCompleted', 'wireReceiveCompleted']
PINS = []


def need(value, message):
    if not value:
        raise ValueError(message)


def unique(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'Duplicate JSON key')
        result[key] = value
    return result


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def read(path, limit=8 * 1024**2):
    need(path.is_file() and not path.is_symlink(), 'Regular retained file required')
    before = path.stat()
    need(0 < before.st_size <= limit, 'Input byte bound')
    raw = path.read_bytes()
    after = path.stat()
    need((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
         (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns), 'Input changed while read')
    pin = dict(path=str(path), bytes=len(raw), sha256=digest(raw))
    PINS.append(pin)
    return raw, pin


def document(path, limit=8 * 1024**2):
    raw, pin = read(path, limit)
    value = json.loads(raw, object_pairs_hook=unique,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))
    return value, pin


def integer(value):
    need(type(value) is int and 0 <= value < 2**64, 'Unsigned scalar required')
    return value


def stats(values):
    need(values and all(type(v) is int and v >= 0 for v in values), 'Bounded integer intervals required')
    ordered = sorted(values)
    return dict(count=len(values), totalNanoseconds=sum(values),
                meanNanoseconds=sum(values)/len(values), medianNanoseconds=statistics.median(values),
                p95NearestRankNanoseconds=ordered[math.ceil(len(values)*.95)-1],
                minimumNanoseconds=ordered[0], maximumNanoseconds=ordered[-1])


def profile(label, directory, join, expected_mode, expected_policy, build_pin):
    job, job_pin = document(directory/'job.json', 65536)
    terminal, terminal_pin = document(directory/'terminal.json')
    result, stdout_pin = document(directory/'native/worker-0.stdout')
    need(terminal_pin['sha256'] == join['terminalSHA256'] and stdout_pin['sha256'] == join['stdoutSHA256'],
         'Accepted comparison identity join')
    need(terminal['result'] == result and terminal['jobSHA256'] == job_pin['sha256'], 'Raw result/job join')
    need(terminal['status'] == 'completed' and terminal['exitCodes'] == [0] and
         terminal['groupsAbsent'] is True and terminal['outputComplete'] is True and
         terminal['journalEmptyAndProcessesRetired'] is True and terminal['cleanupErrors'] == [] and
         terminal['primaryFailure'] is None, 'Only complete accepted roles')
    need(result['job'] == job and job['buildIdentitySHA256'] == build_pin and
         job['mode'] == expected_mode and job['prefillPolicy'] == expected_policy and
         (job['promptCount'], job['chunkSize'], job['outputCount'], job['cut']) == (4096, 64, 16, 7),
         'Exact actual workload/build/policy')
    need(result['guardObservationPolicy'] == 'gemma4_invocation_fresh_observation_v1' and
         result['warmupRequests'] == 1 and result['measuredRequests'] == 3 and len(result['samples']) == 4,
         'Qualified guard policy and sample count')
    frames_out = {k: [] for k in ['tokenInterval', 'frameWallClippedToDecode', 'beforeOwner', 'ownerSpan',
                                  'afterOwner', 'interPhaseGaps'] + PHASES}
    guards = {k: dict(count=0, nanoseconds=0, nestedLogicalGuardNanoseconds=0) for k in CATEGORIES}
    requests = []
    for ordinal, sample in enumerate(result['samples']):
        need(sample['ordinal'] == ordinal and sample['warmup'] is (ordinal == 0) and
             sample['requestID'] == job['requestIDs'][ordinal], 'Warmup/request identity')
        if ordinal == 0:
            continue
        need(sample['timingsAreSameProcess'] is True and sample['clockAcrossHostsCompared'] is False and
             sample['requestStateRetired'] is True and sample['mtpEnabled'] is False, 'Local retired timing only')
        times = [integer(x) for x in sample['tokenAgreementNanoseconds']]
        need(len(times) == 16 and all(b > a for a, b in zip(times, times[1:])), 'Token chronology')
        elapsed = times[-1]-times[0]
        need(elapsed == sample['decodeNanoseconds'], 'Decode arithmetic')
        frames = [x for x in sample['frames'] if x['phase'] == 'decode']
        need(len(sample['frames']) == 79 and len(frames) == 15, 'Exact frame schedule')
        owner_total = 0; frame_total = 0
        for index, frame in enumerate(frames):
            need((frame['sequence'], frame['offset'], frame['tokenCount']) == (64+index, 4096+index, 1), 'Decode frontier')
            start, end = integer(frame['startedNanoseconds']), integer(frame['completedNanoseconds'])
            need(times[index] <= start < times[index+1] <= end <= times[index+1]+1_000_000,
                 'Frame and token boundaries')
            rows = frame['ownerPhases']
            need([x['name'] for x in rows] == [p+s for p in PHASES for s in ['.begin', '.end']], 'Owner phase order')
            stamps = [integer(x['timestampNanoseconds']) for x in rows]
            need(start <= stamps[0] and stamps[-1] <= times[index+1] and
                 all(b >= a for a,b in zip(stamps, stamps[1:])), 'Same-frame owner chronology')
            for i, row in enumerate(rows):
                need(row['tokenCount'] == 1 and row['committedTokens'] == 4096+index+(i == 7), 'Owner state frontier')
            # Frame completion is sampled a few ns after token agreement. Clip
            # its final edge to avoid subtracting outside the decode interval.
            clipped = min(end, times[-1])-start
            span = stamps[-1]-stamps[0]
            durations = [stamps[i+1]-stamps[i] for i in range(0,8,2)]
            for name, value in zip(PHASES, durations):
                frames_out[name].append(value)
            for name, value in [('tokenInterval',times[index+1]-times[index]),
                                ('frameWallClippedToDecode',clipped), ('beforeOwner',stamps[0]-start),
                                ('ownerSpan',span), ('afterOwner',min(end,times[-1])-stamps[-1]),
                                ('interPhaseGaps',span-sum(durations))]:
                frames_out[name].append(value)
            owner_total += span; frame_total += clipped
        metrics = sample['guardMetrics']
        need(metrics['boundary'] == 'request-start_to_first-token-agreement_and_first-to-last-agreement', 'Metric boundary')
        decode = metrics['decode']
        need(decode['schema'] == 'gemma4_guard_wall_counters_v1' and decode['overflow'] is False and
             decode['sameProcessClock'] is True and decode['categoriesAreInclusive'] is True and
             decode['extraOSReads'] == 0 and decode['extraNativeEvaluations'] == 0, 'Metric scope')
        need([x['category'] for x in decode['records']] == CATEGORIES, 'Metric categories')
        local = {x['category']:x for x in decode['records']}
        for category, record in local.items():
            for key in guards[category]:
                guards[category][key] += integer(record[key])
        wire = sum(local[x]['nanoseconds'] for x in CATEGORIES[-2:])
        nested = sum(local[x]['nestedLogicalGuardNanoseconds'] for x in CATEGORIES[-2:])
        logical = local['logicalGuard']['nanoseconds']
        need(0 <= nested <= wire and nested <= logical and wire+logical-nested <= elapsed,
             'Inclusive guard/wire accounting')
        requests.append(dict(ordinal=ordinal, requestID=sample['requestID'], decodeNanoseconds=elapsed,
            decodeTokens=15, ownerSpanNanoseconds=owner_total, frameWallNanoseconds=frame_total,
            betweenFrameNanoseconds=elapsed-frame_total, wireInclusiveNanoseconds=wire,
            wireNestedLogicalGuardNanoseconds=nested, wireExcludingNestedGuardNanoseconds=wire-nested,
            logicalGuardOutsideWireNanoseconds=logical-nested,
            remainderAfterWireAndOutsideGuardNanoseconds=elapsed-wire-logical+nested))
    count = 45
    for record in guards.values():
        record.update(callsPerDecodeToken=record['count']/count,
                      meanNanosecondsPerDecodeToken=record['nanoseconds']/count,
                      meanNanosecondsPerCall=record['nanoseconds']/record['count'] if record['count'] else None)
    disjoint_keys = ['decodeNanoseconds','wireInclusiveNanoseconds','wireNestedLogicalGuardNanoseconds',
                    'wireExcludingNestedGuardNanoseconds','logicalGuardOutsideWireNanoseconds',
                    'remainderAfterWireAndOutsideGuardNanoseconds','betweenFrameNanoseconds']
    binding = result['samples'][1]['binding']
    return dict(role=label, source=stdout_pin, terminal=terminal_pin, job=job_pin,
        nativePID=terminal['nativePIDs'][0], membershipEpoch=job['membershipEpoch'],
        layerOwnership=[x['globalIndex'] for x in binding['layers']], binding={k:v for k,v in binding.items() if k!='layers'},
        measuredRequests=3, excludedWarmupRequests=1, decodeTokens=count, requests=requests,
        localIntervals={k:stats(v) for k,v in frames_out.items()}, guardMetrics=guards,
        meanNanosecondsPerDecodeToken={k:sum(x[k] for x in requests)/count for k in disjoint_keys})


def main():
    serial, serial_pin = document(SERIAL/'comparison-v2.json', 65536)
    overlap, overlap_pin = document(OVERLAP/'comparison-overlap.json', 65536)
    need(serial['status'] == overlap['status'] == 'passed', 'Accepted comparison required')
    need(overlap['retainedEvidenceJoins'][:3] == serial['retainedEvidenceJoins'], 'Matched solo/serial provenance')
    build, build_pin = document(ROOT/'build/GemmaResidentBenchmark-build-6.json',65536)
    composition, composition_pin = document(ROOT/'build/applied-uncached-sidecars.json',131072)
    native = build['nativeSHA256']
    need(native == serial['benchmarkNativeSHA256'] == overlap['benchmarkNativeSHA256'] and
         build['sourcesSHA256'] == composition_pin['sha256'] and build['exitCode'] == 0 and
         build['compilerReaped'] is True, 'Actual build/source chain')
    sources = []
    names = ['Gemma4BenchmarkDriver.swift','Gemma4BenchmarkForward.swift','Gemma4BenchmarkWire.swift',
        'Gemma4BenchmarkWirePayload.swift','Gemma4BenchmarkGuardMetrics.swift','Gemma4BenchmarkRuntime.swift',
        'Gemma4BenchmarkEntry.swift','Gemma4BenchmarkGuardObservation.swift','Gemma4BenchmarkGuardInvocation.swift',
        'Gemma4BenchmarkResourceOwner.swift','QwenDenseStageLoadResources.swift','QwenResidentRequestResources.swift',
        'CollectivePointToPoint.swift','CBv2OwnedRequestState.swift','Tracing/CBv2OwnerPhaseObservation.swift']
    for name in names:
        path = (ROOT.parent/'gemma4-benchmark-guard-metrics-20260920/Runtime'/name
                if name == 'QwenDenseStageLoadResources.swift' else RUNTIME/name)
        raw, pin = read(path,131072)
        rows = [x for x in composition['files'] if x['path'].endswith('/'+name)]
        if rows:
            need(len(rows)==1 and rows[0]['sha256']==pin['sha256'], 'Source composition pin')
            pin['lineage'] = 'actual build composition member'
        else:
            old = ROOT.parent/'gemma4-short-correctness-draft-20260916/build/workspace/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'/name
            original, prior_pin = read(old,131072)
            need(raw==original, 'Inherited source differs from original clone base')
            pin['lineage'] = 'byte-identical to original APFS clone base source'
            pin['baseSource'] = prior_pin
        sources.append(pin)
    roles = [profile('solo',SERIAL/'solo/full',overlap['retainedEvidenceJoins'][0],'full','serial',native),
             profile('rank0',OVERLAP/'pair/stage0',overlap['retainedEvidenceJoins'][3],'stage0','oneChunkLookahead',native),
             profile('rank1',OVERLAP/'pair/stage1',overlap['retainedEvidenceJoins'][4],'stage1','oneChunkLookahead',native)]
    report = dict(schema='gemma4_retained_decode_profile_v1', status='extracted', nativeSHA256=native,
        workload=dict(promptTokens=4096,chunkTokens=64,outputTokens=16,cut=7,mtpEnabled=False,
                      promptSHA256=json.loads((SERIAL/'full.json').read_text())['promptFileSHA256']),
        acceptedComparisons=[serial_pin,overlap_pin], build=build_pin, composition=composition_pin,
        roles=roles, sourceEvidence=sources,
        limits=['Every duration is subtracted only within its originating native process.',
                'Owner phases include their existing checks and runtime work; they are not GPU kernel times.',
                'Guard categories are inclusive and overlap owner/wire intervals; never sum all categories.',
                'Wire minus nested guard still includes peer compute, scheduler wait, C evaluation and CPU/GPU completion.',
                'No network latency, bandwidth, encryption rate or cross-host wait duration is isolated.',
                'Three measured requests per role, 15 continuation tokens each; warmup excluded.',
                'No new replay of raw physical resources, sidecar numerical bytes or native binary; accepted comparison joins are reused.',
                'No optimization is implemented or performance gain predicted.'],
        runtimeChanged=False, modelExecuted=False, remoteExecuted=False, compilerExecuted=False)
    for pin in PINS:
        need(digest(Path(pin['path']).read_bytes()) == pin['sha256'], 'Retained input changed before publication')
    raw = (json.dumps(report,indent=2,sort_keys=True)+'\n').encode()
    with (OUT/'profile.json').open('xb') as f:
        f.write(raw)
    print(json.dumps(dict(profileSHA256=digest(raw),roles=[dict(role=x['role'],
        milliseconds={k:v/1e6 for k,v in x['meanNanosecondsPerDecodeToken'].items()},
        ownerMilliseconds={k:v['meanNanoseconds']/1e6 for k,v in x['localIntervals'].items()},
        guardMilliseconds={k:v['meanNanosecondsPerDecodeToken']/1e6 for k,v in x['guardMetrics'].items()}) for x in roles]),indent=2))


if __name__ == '__main__':
    main()
