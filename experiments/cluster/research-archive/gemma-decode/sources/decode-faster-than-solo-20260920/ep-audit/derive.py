"""Read only small retained metadata/evidence; derive arithmetic, not admission or TPS."""
import collections
import json
from pathlib import Path

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
META = ROOT / 'gemma4-full-model-ep-physical-20260920/deployment/metadata'
CASE = ROOT / 'gemma4-full-model-ep-physical-20260920/cases/p32-c16-o2-ep16-112-v1'
headers = {}
for path in sorted(META.glob('*.header.json')):
    headers.update(json.loads(path.read_text()))
headers = {k: v for k, v in headers.items() if k.startswith('language_model.')}
assert len(headers) == 1339
categories = collections.defaultdict(lambda: {'sourceBytes': 0, 'float32MetadataOperandProxy': 0, 'castReserveBytes': 0})
for name, value in headers.items():
    category = next((category for fragment, category in (
        ('.experts.', 'expert'), ('.mlp.', 'dense'), ('.self_attn.', 'attention'),
        ('.router.', 'router'), ('.embed_tokens.', 'embedding')) if fragment in name), 'other')
    size = value['data_offsets'][1] - value['data_offsets'][0]
    casts = name.endswith(('.scales', '.biases')) and value['dtype'] in ('BF16', 'F16')
    categories[category]['sourceBytes'] += size
    categories[category]['float32MetadataOperandProxy'] += size * (2 if casts else 1)
    categories[category]['castReserveBytes'] += size * 2 if casts else 0

report = json.loads((CASE / 'pair/expert0/native/worker-0.stdout').read_text())
observations = report['exchangeObservations']
assert len(observations) == 150
decode = [x['scope'] for x in observations if x['scope']['binding']['purpose'] == 'request'
          and x['scope']['frame']['phase'] == 'decode']
assert len(decode) == 30
counts = [sum(x['assignmentCounts'][r] for x in decode) for r in (0, 1)]
assert counts == [27, 213]

h, layers, k = 2816, 30, 8
projection_mac = {
    'sparseExperts': layers * k * 3 * h * 704,
    'denseBranch': layers * 3 * h * 2112,
    'attentionProjections': 25 * h * (2 * 16 * 256 + 2 * 8 * 256)
                           + 5 * h * (2 * 16 * 512 + 2 * 512),
    'router': layers * h * 128,
    'outputHead': h * 262144,
}
attention = {str(n): 25 * 2 * 16 * 256 * 1024 + 5 * 2 * 16 * 512 * n
             for n in (4097, 4223)}
mac_fraction = {n: projection_mac['sparseExperts'] / (sum(projection_mac.values()) + a)
                for n, a in attention.items()}
kv_once = 25 * 2 * 1024 * 8 * 256 * 2 + 5 * 2 * 4097 * 2 * 512 * 2
read_proxies = {}
for field in ('sourceBytes', 'float32MetadataOperandProxy'):
    parts = {name: value[field] // 16 if name == 'expert' else value[field]
             for name, value in categories.items()}
    read_proxies[field] = {'parts': parts, 'parameterBytes': sum(parts.values()),
                          'expertFraction': parts['expert'] / sum(parts.values()),
                          'oneBF16KVReadBytes': kv_once,
                          'fractionWithOneKVRead': parts['expert'] / (sum(parts.values()) + kv_once)}

expert_storage = categories['expert']['sourceBytes']
base_storage = sum(x['sourceBytes'] for x in categories.values()) - expert_storage
expert_cast = categories['expert']['castReserveBytes']
base_cast = sum(x['castReserveBytes'] for name, x in categories.items()
                if name not in ('expert', 'embedding'))
selected64 = base_storage + expert_storage // 2
casts64 = base_cast + expert_cast // 2
largest = max(x['data_offsets'][1] - x['data_offsets'][0] for x in headers.values())
state = 25 * 2 * 1024 * 8 * 256 * 4 + 5 * 2 * 4224 * 2 * 512 * 4
# Deliberately omits all remaining trunk/EP temporary, host-report, rounding,
# transport and constructor workspace charges: a rejection lower bound only.
minimum_load_terms = {
    'selected64LogicalBytes': selected64, 'possiblePersistentF32CastReserve': casts64,
    'headCastReserve': categories['embedding']['castReserveBytes'],
    'fullPlusWindowF32StateReserve': state,
    'oneSourceHostAndOneNativeCopyLogical': 2 * largest,
    'alignedReadScratch': 8 * 1024 * 1024 + 16384,
    'unchangedLoadingHeadroom': 4 * 1024**3,
}
assert selected64 == 8044505148 and casts64 == 1634406400
prelaunch = json.loads((CASE / 'pair/expert0/resources.jsonl').read_text().splitlines()[0])
zero_layers = sum(0 in x['assignmentCounts'] for x in decode)
out = {
    'schema': 'gemma_ep_read_only_arithmetic_audit_v1',
    'noHardwareExecution': True, 'notAnAdmissionReceipt': True,
    'categories': dict(categories), 'projectionMACs': projection_mac,
    'attentionQKAndAVMACs': attention, 'sparseMACFraction': mac_fraction,
    'readProxiesNotMeasuredDRAM': read_proxies,
    'actualSingleDecode': {'assignmentsByRank': counts, 'rank0ZeroAssignmentLayers': zero_layers,
                          'rank1AssignmentFraction': counts[1] / sum(counts)},
    'replicated64InitialFreeRejectionLowerBound': {
        'terms': minimum_load_terms, 'bytes': sum(minimum_load_terms.values()),
        'retained24PrelaunchActualFreeBytes': prelaunch['actualFreeBytes'],
        'exceedsRetainedFreeBy': sum(minimum_load_terms.values()) - prelaunch['actualFreeBytes']},
    'temporaryLivenessC64HypotheticalNotAdmitted': {
        'twoSlotEPLogicalBytes': 2 * 64 * 8 * (9 * 2816 * 4 + 3 * 704 * 4 + 7 * 4),
        'thirtyToTwoSlotLogicalDifference': 28 * 64 * 8 * (9 * 2816 * 4 + 3 * 704 * 4 + 7 * 4),
        'slidingAttentionExposureCap': 1024 - 1 + 64},
    'controls': {'actualPerDirection': 607, 'nativeControlOperationsPerRank': 607 * 4,
                 'nativeOperationsInActualDecodeIncludingCommit': 30 * 18 - zero_layers + 4,
                 'logicalExpertRowBytesAcrossBothDirectionsPerDecode': 30 * 8 * 2816 * 2,
                 'naiveP4096C64O128LayerExchanges': (2 + 64 + 127) * 30,
                 'naiveControlsPerDirection': (2 + 64 + 127) * 30 * 4 + (64 + 127) + 4},
}
print(json.dumps(out, indent=2, sort_keys=True))
