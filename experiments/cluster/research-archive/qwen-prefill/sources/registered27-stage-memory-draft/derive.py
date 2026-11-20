"""Metadata/source-only ledger; no runtime measurement or execution admission."""
import hashlib, json, pathlib, re

ROOT = pathlib.Path('/Users/developer/DarkbloomDev/d-inference')
HERE = pathlib.Path(__file__).resolve().parent
INPUT = ROOT / 'experiments/cluster/inference/Tests/RegisteredDenseProfiles/retained-inputs.json'
EXPECTED = '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25'
raw = INPUT.read_bytes()
assert hashlib.sha256(raw).hexdigest() == EXPECTED
tensors = json.loads(raw)['twentySeven']['canonicalTensors']
assert len(tensors) == 1847 and sum(t['byteCount'] for t in tensors) == 15132802048
assert {t['sourceDType'] for t in tensors} == {'U32', 'BF16'}
P = 16384  # Conditional example, never an observed runtime policy.
def bound(n):
    aligned = n if n <= P else (n + P - 1) // P * P
    return aligned + min(aligned - 1, 2 * P - 1)
def owner(t):
    match = re.search(r'\.layers\.(\d+)\.', t['name'])
    return int(match[1]) // 32 if match else (0 if '.embed_tokens.' in t['name'] else 1)
stages = []
for role in (0, 1):
    entries = [t for t in tensors if owner(t) == role]
    active = sum(t['byteCount'] for t in entries)
    inert = [5120 * 2] * (2 if role == 0 else 1)
    host = max(t['byteCount'] for t in entries)
    rounded = sum(bound(t['byteCount']) for t in entries) + sum(map(bound, inert))
    fusion = sum(t['byteCount'] for t in entries if '.linear_attn.' in t['name'] and
                 t['name'].split('.')[-2] in ['in_proj_qkv', 'in_proj_z', 'in_proj_b', 'in_proj_a'])
    kv_native_capacity = 8 * (2 * 8193 * 4 * 256 * 2 + 4)
    recurrent_native = 24 * (3 * 10240 * 2 + 48 * 128 * 128 * 4)
    final = 8 * (2 * 8192 * 4 * 256 * 2 + 4) + recurrent_native
    named = dict(allKVCapacityAndOffsetsBytes=8 * (2 * 8193 * 4 * 256 * 4 + 4),
        threeRecurrentGenerationsBytes=3 * 24 * (3 * 10240 * 4 + 48 * 128 * 128 * 4),
        largestSingleHostStateComponentBytes=8193 * 4 * 256 * 4,
        twoBoundaryArraysBytes=2 * 512 * 5120 * 4)
    stages.append(dict(stage=role, activeCount=len(entries), activeBytes=active,
        logicalInertBytes=sum(inert), logicalLoadedBytes=active+sum(inert),
        materializedDTypeExpansionBytes=0, largestHostBytes=host,
        conservativeLoadedPlusOneHostBytes=active+sum(inert)+host,
        conditional16KiBAllBufferBound=rounded,
        conditionalInitialRPlus2HPlus4GiB=rounded+2*host+4*2**30,
        conditionalAllocatorIncrementRPlusHPlus2GiB=rounded+host+2*2**30,
        finalStateComponents=72, finalStateLogicalBytes=final,
        nativeCapacityAndRecurrentLogicalBytes=kv_native_capacity+recurrent_native,
        namedStateLedger=named, namedStateLedgerTotal=sum(named.values()),
        allGDNFusionReplacementAllowance=fusion,
        partialPrefillLedgerBytes=active+sum(inert)+host+fusion+sum(named.values())))
assert [(s['activeCount'], s['activeBytes']) for s in stages] == [(923,7566395904),(924,7566406144)]
assert all(s['partialPrefillLedgerBytes'] == 10168019488 and s['finalStateLogicalBytes'] == 345407520 for s in stages)
source_names = [
 'experiments/cluster/inference/Sources/ClusterInference/' + n + '.swift' for n in [
 'VerifiedCheckpoint','SafeTensorReader','VerifiedQwenLayerStageLoading','QwenDenseStorageRequirement',
 'QwenDenseStateBudget','QwenLongPrefillTensorBudget','QwenDenseResourcePlanning','LocalCorrectnessStorage',
 'CBv2OwnedRequestState','CBv2RequestGeometry']]
source_names += [
 'libs/mlx-swift/Source/MLX/AllocationFootprint.swift',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/memory.h',
 'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/allocator.cpp',
 'libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift',
 'libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/AttentionV1.swift',
 'libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/SequenceKV/ContiguousKVBackend.swift',
 'libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/SequenceKV/FullSequenceKV.swift',
 'provider-swift/Sources/ProviderCore/Models/ModelRuntimeRequirements.swift']
result = dict(schemaVersion=1, scope='retained metadata and source only', inputSHA256=EXPECTED,
    sourcePins={n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in source_names},
    allocationPageBytesAssumption=P, allocationPolicyObserved=False, executionAuthorized=False,
    isWholeProcessMemoryBound=False, stages=stages,
    absoluteActualFreeFloorBytes=6*2**30, reclaimableCanAdmit=False,
    fullCanonicalTextBytes=15132802048, manifestFileVerificationBytes=16320415757)
assert INPUT.read_bytes() == raw
with (HERE/'ledger.json').open('x') as f: json.dump(result,f,indent=2,sort_keys=True); f.write('\n')
print(json.dumps({'metadataChecksPassed':True,'stagePartialBytes':[s['partialPrefillLedgerBytes'] for s in stages]}))
