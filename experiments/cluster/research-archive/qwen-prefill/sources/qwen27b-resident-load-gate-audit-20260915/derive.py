"""Pinned metadata/source arithmetic and retained resource observations; no native execution."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
BUILD = ROOT / 'qwen27b-owner-validation-build-20260915'
OUT = Path(__file__).resolve().parent
GIB, PAGE = 1_073_741_824, 16_384
seen = {}


def raw(path):
    value = path.read_bytes()
    assert len(value) <= 16 * 1024 * 1024
    seen[str(path)] = dict(path=str(path), bytes=len(value), sha256=hashlib.sha256(value).hexdigest())
    return value


def read(path):
    return json.loads(raw(path))


def bound(n):
    assert type(n) is int and n >= 0
    if not n:
        return 0
    normalized = ((n + PAGE - 1) // PAGE) * PAGE if n > PAGE else n
    return normalized + min(normalized - 1, 2 * PAGE - 1)


def main():
    snapshot = read(BUILD / 'source-snapshot.json')
    members = {x['path']: x for x in snapshot['members']}
    runtime = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/'
    mlx = 'libs/mlx-swift/Source/Cmlx/mlx/mlx/'
    sources = [runtime + name for name in [
        'QwenResidentLoading.swift', 'QwenDenseStageLoadPolicy.swift', 'QwenDenseStageLoadResources.swift',
        'QwenResidentRuntime+Load.swift', 'QwenResidentAllocatorPolicy.swift', 'QwenResidentSource.swift',
        'PreparedQwenCheckpoint.swift', 'PreparedQwenLayerStage.swift', 'VerifiedCheckpoint.swift',
        'VerifiedQwenLayerStageLoading.swift', 'SafeTensorReader.swift', 'CheckpointAlignedReadAccounting.swift']]
    sources += [mlx + 'memory.h', mlx + 'backend/metal/allocator.cpp']
    for path in sources:
        value = raw(BUILD / 'workspace' / path)
        assert len(value) == members[path]['bytes'] and hashlib.sha256(value).hexdigest() == members[path]['sha256']
    constructor = read(ROOT / 'qwen27b-expected-generation-identity-20260915/inputs/constructor.stdout.jsonl')
    assert constructor['planSHA256'] == '980b0f6ece0a078c284143d8af05c1532c2fdd7f0a6b1a06682b7bcc94b377d3'
    stages = []
    for rank, stage in enumerate(constructor['stages']):
        active = stage['expectedActiveTensors']
        inert = [p for module in stage['installedLazyInertModules'] for p in module['parameters']]
        assert [x['localName'] for x in active] == sorted(x['localName'] for x in active)
        active_bytes = sum(x['byteCount'] for x in active)
        inert_bytes = sum(x['byteCount'] for x in inert)
        remaining = sum(bound(x['byteCount']) for x in active + inert)
        host = max(x['byteCount'] for x in active)
        scratch = 8 * 1024 * 1024 + PAGE
        required = max(6 * GIB, remaining + 2 * host + scratch + 4 * GIB)
        allocator_extra = remaining + host + 2 * GIB
        assert len(active) == [923, 924][rank]
        assert active_bytes == [7_566_395_904, 7_566_406_144][rank]
        assert inert_bytes == [20_480, 10_240][rank]
        assert remaining == 7_590_359_139 and host == 635_699_200
        assert required == 13_165_129_827 and allocator_extra == 10_373_541_987
        stages.append(dict(rank=rank, activeCount=len(active), activeLogicalBytes=active_bytes,
            inertLogicalBytes=inert_bytes, initialRemainingBoundBytes=remaining, maximumHostTensorBytes=host,
            scratchBytes=scratch, initialRequiredFreeBytes=required, initialRequiredFreeGiB=required / GIB,
            initialAllocatorAdditionalBytes=allocator_extra, allocatorActiveCacheAndLimitObserved=False,
            firstSourceTensor=active[0]['sourceName']))
    runs = []
    for name in ['qwen27b-owner-native-diagnostic-rerun-v2-20260915',
                 'qwen27b-owner-diagnostic-drain-rerun-20260915']:
        records = [json.loads(line) for line in raw(ROOT / name / 'physical-1/resources-0.jsonl').splitlines()]
        begin = records[0]['startedMonotonicNS']
        trajectory = []
        for value in records:
            page = int(re.search(r'page size of (\d+) bytes', value['rawVMStat'])[1])
            free = int(re.search(r'Pages free:\s+(\d+)\.', value['rawVMStat'])[1]) * page
            assert page == PAGE and free == value['actualFreeBytes']
            trajectory.append(dict(ordinal=value['ordinal'],
                samplerRelativeSeconds=(value['startedMonotonicNS'] - begin) / 1e9,
                actualFreeBytes=free, marginAgainstInitialFreeGateBytes=free - required))
        runs.append(dict(parent=name, rank=0, samples=len(trajectory), trajectory=trajectory,
            allSamplesBelowInitialFreeGate=all(x['actualFreeBytes'] < required for x in trajectory),
            minimumActualFreeBytes=min(x['actualFreeBytes'] for x in trajectory),
            maximumActualFreeBytes=max(x['actualFreeBytes'] for x in trajectory),
            nativeGateOrdinalOrOperandObserved=False))
    report = dict(schema='qwen27b_resident_load_gate_source_audit_v1', stages=stages, runs=runs,
        sourceFacts=[
            'VerifiedCheckpoint.digest requests F_NOCACHE before whole-file hashing through a bounded 4 MiB buffer; this does not evict preexisting cache.',
            'Source verification and lazy full/other/local constructor metadata precede gate initialization.',
            'materializeVerifiedQwenLayerStage requests F_NOCACHE and disables read-ahead before selected aligned payload reads.',
            'beforeRead observes with the current tensor still in remaining, then increments next before actual read/eval.',
            'The materializer rechecks after eval/synchronize and after parameter installation; next counts admitted reads, not necessarily completed reads.',
            'TensorDescriptor.read returns copied MLX storage and does not retain its host Data; actual file-cache absence remains unproven.',
            'The dedicated worker sets freed-buffer cache limit zero before collective/load; memoryLimit is not changed in the reviewed resident load path.'],
        interpretation=[
            'The current run has proven combined load-policy refusal and all sampled rank0 free values below the metadata-derived initial free requirement; the internal sampled operand is absent.',
            'The earlier V2 began above the initial requirement and shows a late transient drop followed by recovery. Sampler time does not identify native load phase or tensor progress.',
            'A materially larger actual-free result after the existing authorized purge can justify an unchanged guarded retry. Crossing only the initial threshold cannot certify the whole load.',
            'No source-supported missing cache-bypass fix or reason to lower any budget/floor was found. Operand diagnostics are the next precise measurement if headroom cannot materially improve or refusal repeats.'],
        limits=['No native gate OS/allocator snapshot was recorded in these runs.',
                'The allocator footprint is rederived from pinned C++ policy and observed 16 KiB pages, not a newly executed native query.',
                'Resource samples are discrete and use only within-sampler clock differences.',
                'No compiler, model, native, remote or purge execution by this audit.'], inputs=list(seen.values()))
    (OUT / 'review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(passed=True, stages=stages,
        reviewSHA256=hashlib.sha256((OUT / 'review.json').read_bytes()).hexdigest())))


if __name__ == '__main__':
    main()
