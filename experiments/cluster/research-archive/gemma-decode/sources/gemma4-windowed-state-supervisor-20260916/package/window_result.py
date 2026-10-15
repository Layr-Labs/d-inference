"""Closed contract for actual mixed full/window cache execution, not Gemma weights."""
from binding_common import parse, require, same

GROUPS = ['actual-prefill2-decode1-type-probe', 'mixed-bf16-fp32-full-window',
    'below-at-after-window-and-large-chunks', 'multiple-wraps-cpu-chronology',
    'metadata-only-inspection', 'cpu-snapshot-survives-mutation', 'empty-recurrent-and-row-retirement',
    'range-global-layout-fingerprint-separation']
GROUPS += ['actual-refusal-and-retirement-' + name for name in ['row-identity', 'device-position',
    'native-dtype', 'descriptor-shape', 'descriptor-window', 'lost-history', 'pending-window-write',
    'output-validation', 'chunk-bound']]
GROUPS += ['actual-post-evaluation-cancellation-retirement', 'actual-tiny-qwen-full-and-recurrent-forward',
    'legacy-v1-snapshot-exact-control', 'legacy-nonempty-missing-recurrent-refusal']
EXPECTED = dict(fixture='actual-cbv2-mixed-full-window-state', passed=GROUPS,
    observedDTypes=['bfloat16', 'float32'], windowTokens=4, maximumTokens=32, maximumChunkTokens=7,
    exactNativeKVCapacityBytes=8192, conservativeBackendReservationBytes=12288,
    retainedWindowTemporaryBoundBytes=14336, maximumNativeActiveIncrementBytes=64*1024*1024,
    sharedStateAndCacheExecuted=True, actualPrefill2Decode1Probe=True, legacyQwenActualForward=True,
    gemmaModelExecuted=False, registeredWeightsLoaded=False, outerGemmaAdmissionQualified=False,
    distributedExecutionQualified=False)


def validate_result(raw):
    require(type(raw) is bytes and 0 < len(raw) <= 16384, 'Native window result exceeds its bound')
    value = parse(raw)
    same(value, EXPECTED, 'Complete actual window-state result')
    return value
