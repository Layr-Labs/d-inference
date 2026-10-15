"""Metadata-only alternative-cut arithmetic; no fabricated Plan/profile identities."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
BUILD = ROOT / 'qwen27b-owner-validation-build-20260915'
OUT = Path(__file__).resolve().parent
PAGE, GIB = 16_384, 1_073_741_824
CUTS = [16, 24, 32, 40]
seen = []


def read(path):
    raw = path.read_bytes()
    seen.append(dict(path=str(path), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
    return raw


def bound(n):
    if n == 0:
        return 0
    rounded = (n + PAGE - 1) // PAGE * PAGE if n > PAGE else n
    return rounded + min(rounded - 1, 2 * PAGE - 1)


def mapping(name, cut):
    match = re.fullmatch(r'language_model\.model\.layers\.(0|[1-9][0-9]*)\.(.+)', name)
    if match:
        layer = int(match[1])
        assert 0 <= layer < 64
        rank = int(layer >= cut)
        return rank, 'language_model.model.layers.' + str(layer - (cut if rank else 0)) + '.' + match[2]
    if name.startswith('language_model.model.embed_tokens.'):
        return 0, name
    assert name == 'language_model.model.norm.weight' or name.startswith('language_model.lm_head.')
    return 1, name


def main():
    snapshot = json.loads(read(BUILD / 'source-snapshot.json'))
    by_path = {x['path']: x for x in snapshot['members']}
    prefix = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/'
    sources = [prefix + x for x in ['QwenLayerStagePlan.swift', 'QwenLayerStageMetadata.swift',
        'QwenLayerStageCandidates.swift', 'QwenRegisteredDenseModelProfile.swift',
        'QwenResidentModelDefinition.swift', 'QwenResidentAdmission.swift', 'QwenResidentLoading.swift',
        'QwenDenseStageLoadPolicy.swift', 'CheckpointAlignedReadAccounting.swift']]
    sources += ['libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/WorkerConfiguration.swift',
        'libs/mlx-swift/Source/Cmlx/mlx/mlx/memory.h',
        'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/allocator.cpp']
    for path in sources:
        raw = read(BUILD / 'workspace' / path)
        assert len(raw) == by_path[path]['bytes'] and hashlib.sha256(raw).hexdigest() == by_path[path]['sha256']
    owner = ROOT / 'owner-retirement-controls-build-20260915/Entries/qwen27b'
    for name in ['main.swift', 'Qwen27BQualificationScope.swift']:
        read(owner / name)
    raw = read(ROOT / 'qwen27b-expected-generation-identity-20260915/inputs/constructor.stdout.jsonl')
    assert hashlib.sha256(raw).hexdigest() == '563414858fcec6228884c13b9b1aa8669d1c22097bd10b848a60f820aca51794'
    constructor = json.loads(raw)
    all_tensors = [x for stage in constructor['stages'] for x in stage['expectedActiveTensors']]
    assert len(all_tensors) == len({x['sourceName'] for x in all_tensors}) == 1847
    for rank, stage in enumerate(constructor['stages']):
        for tensor in stage['expectedActiveTensors']:
            assert mapping(tensor['sourceName'], 32) == (rank, tensor['localName'])
    leaf_ledger = [dict(sourceName=x['sourceName'], logicalBytes=x['byteCount'],
        loadedDType=x['loadedDType'], allocationBoundBytes=bound(x['byteCount']),
        ranksByCut=[mapping(x['sourceName'], cut)[0] for cut in CUTS])
        for x in sorted(all_tensors, key=lambda x:x['sourceName'])]
    result = []
    for cut in CUTS:
        ranks = []
        for rank in (0, 1):
            leaves = [x for x in leaf_ledger if x['ranksByCut'][CUTS.index(cut)] == rank]
            inert = [x for module in constructor['stages'][rank]['installedLazyInertModules'] for x in module['parameters']]
            inert_bound = sum(bound(x['byteCount']) for x in inert)
            remaining = sum(x['allocationBoundBytes'] for x in leaves) + inert_bound
            host = max(x['logicalBytes'] for x in leaves)
            scratch = 8 * 1024**2 + PAGE
            free_required = max(6 * GIB, remaining + 2 * host + scratch + 4 * GIB)
            ranks.append(dict(rank=rank, activeTensorCount=len(leaves), activeLogicalBytes=sum(x['logicalBytes'] for x in leaves),
                inertLogicalBytes=sum(x['byteCount'] for x in inert), inertAllocationBoundBytes=inert_bound,
                initialRemainingAllocationBoundBytes=remaining, largestHostTensorBytes=host,
                scratchBytes=scratch, initialRequiredActualFreeBytes=free_required,
                initialRequiredActualFreeGiB=free_required/GIB,
                initialAllocatorAdditionalBytes=remaining + host + 2*GIB))
        assert sum(x['activeTensorCount'] for x in ranks) == 1847
        assert sum(x['activeLogicalBytes'] for x in ranks) == 15_132_802_048
        result.append(dict(cut=cut, ranges=[[0, cut], [cut, 64]], structuralPlanCompatible=True,
            currentNativeAndResidentProfileAccept=cut in [4, 8, 12, 16, 32],
            currentOwnerAccept=cut == 32, ranks=ranks))
    assert all(x['initialRequiredActualFreeBytes'] == 13_165_129_827 for x in result[2]['ranks'])
    ledger = dict(cuts=CUTS, pageBytes=PAGE, sourceLeaves=leaf_ledger,
        inertByRank=[s['installedLazyInertModules'] for s in constructor['stages']])
    (OUT / 'per-leaf-ledger.json').write_text(json.dumps(ledger, indent=2) + '\n')
    report = dict(schema='qwen27b_alternative_cut_initial_load_arithmetic_v1', cuts=result,
        currentNativeSupportedCuts=[4, 8, 12, 16, 32], currentOwnerCut=32,
        perLeafLedgerSHA256=hashlib.sha256((OUT / 'per-leaf-ledger.json').read_bytes()).hexdigest(),
        exactCut32SourceAndLocalMappingReplay=True,
        interpretation=['Cut16 is accepted by the existing native/profile, but the current private owner requires32 and would need a separately pinned owner/configuration derivative.',
            'Cuts24 and40 preserve the four-layer attention phase but are outside the current registered resident allowlist. Widening that list also changes its planningScopeFields/profile fingerprint; no such change is made here.',
            'All values are initial load-policy requirements, not Ready/request/state sufficiency or whole-process physical-memory guarantees.',
            'Allocator additional bytes exclude the dynamic active/cache terms and are not an observed allocator limit.',
            'Rank0 embedding and rank1 final norm/head ownership follow the current Plan mapping; unchanged inert placeholders are charged per leaf.',
            'No alternative Plan fingerprint or execution permit is fabricated; no compiler/model/native/remote operation occurred.'], inputs=seen)
    (OUT / 'review.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(cuts=result, reviewSHA256=hashlib.sha256((OUT / 'review.json').read_bytes()).hexdigest())))


if __name__ == '__main__':
    main()
