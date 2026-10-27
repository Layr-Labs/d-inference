"""Closed tiny-cache qualification result; no benchmark/model numerics."""
from binding_common import require

GROUPS = [
    'gemma-25-window-5-full-bf16-f32-ledger', 'p4096-o128-width1-through4',
    'per-array-capture-staging-commit-charge', 'unchanged-context-chunk-refusals',
    'capture-coverage-refusals', 'ordinary-and-verification-identities',
    'actual-prefill2-decode1-mixed-dtype-probe', 'all-56-width-prefix-boundary-cases',
    'same-shape-sdk-rollback-reference', 'synthetic-serial-query-output-exact',
    'cpu-encoded-chronological-state-exact', 'zero-partial-all-prefix-publication',
    'rejected-suffix-next-decode-isolation', 'same-owner-capacity-restoration',
    'repeated-rounds-across-window-wraps', 'pre-write-capture-survives-committed-wrap',
    'admission-refusal-before-staging', 'width-and-forward-coverage-refusals',
    'partial-forward-failure-retirement', 'cancel-after-graph-retirement',
    'invalid-prefix-and-replayed-stage-refusals', 'ordinary-access-blocked-during-transaction',
    'admission-and-stage-reentrancy-refused', 'failed-capture-row-capacity-retirement',
]
FLAGS = dict(actualFullWindowRows=True, actualPrefill2Decode1Probe=True,
    sameShapeRollbackReference=True, syntheticSerialOutputExact=True,
    gemmaWeightsExecuted=False, modelBatchShapeNumericsQualified=False,
    assistantOrDistributedQualified=False, wholeModelResourceQualified=False,
    throughputMeasured=False, collectiveCreated=False, collectiveReleased=False)
NUMBERS = dict(maximumVerificationWidth=4, actualPrefixCases=56,
    modeledGemmaLayers=30, modeledSlidingLayers=25, modeledFullLayers=5,
    maximumNativeActiveIncrementBytes=64*1024**2,
    actualFreeHeadroomRequiredBytes=10*1024**3+64*1024**2,
    allocatorHeadroomRequiredBytes=2*1024**3, nativeCacheBytesAfterRelease=0)
CATEGORIES = ['logicalGuard', 'entryGuard', 'ownerGuard', 'environmentGuard',
    'osSnapshot', 'nativeSnapshot', 'outerNativeFault', 'wireSendCompleted', 'wireReceiveCompleted']


def validate_result(value, job, scope=None):
    require(type(value) is dict and set(value) == set(FLAGS) | set(NUMBERS) | {
        'schema', 'fixture', 'passed', 'job', 'scopeSHA256', 'guardMetrics', 'guardObservationPolicy'},
        'Tiny-state result fields differ')
    require(value['schema'] == 'gemma4_owned_mtp_state_qualification_v1'
        and value['fixture'] == 'actual-owned-rectangular-attention-v1'
        and value['passed'] == GROUPS and len(GROUPS) == 24, 'Incomplete or substituted native controls')
    require(value['job'] == job and job['mode'] == 'full' and job['captureEvidence'] is False,
        'Tiny-state job differs')
    for key, wanted in FLAGS.items():
        require(type(value[key]) is bool and value[key] is wanted, 'Wrong tiny-state flag: ' + key)
    for key, wanted in NUMBERS.items():
        require(type(value[key]) is int and value[key] == wanted, 'Wrong tiny-state count/bound: ' + key)
    require(type(value['scopeSHA256']) is str and len(value['scopeSHA256']) == 64
        and all(c in '0123456789abcdef' for c in value['scopeSHA256']), 'Invalid native scope')
    if scope is not None: require(value['scopeSHA256'] == scope, 'Native metadata scope differs')
    require(value['guardObservationPolicy'] == 'gemma4_invocation_fresh_observation_v1', 'Guard policy differs')
    metrics = value['guardMetrics']
    require(type(metrics) is dict and set(metrics) == {'schema', 'records', 'overflow', 'sameProcessClock',
        'categoriesAreInclusive', 'extraOSReads', 'extraNativeEvaluations', 'observerOverheadIncludedInRequestTiming'},
        'Guard counter schema differs')
    require(metrics['schema'] == 'gemma4_guard_wall_counters_v1' and metrics['overflow'] is False
        and metrics['sameProcessClock'] is True and metrics['categoriesAreInclusive'] is True
        and metrics['observerOverheadIncludedInRequestTiming'] is True
        and type(metrics['extraOSReads']) is int and metrics['extraOSReads'] == 0
        and type(metrics['extraNativeEvaluations']) is int and metrics['extraNativeEvaluations'] == 0,
        'Guard counter policy differs')
    require([r['category'] for r in metrics['records']] == CATEGORIES, 'Guard category coverage differs')
    for row in metrics['records']:
        require(set(row) == {'category','count','nanoseconds','nestedLogicalGuardNanoseconds'}
            and all(type(row[k]) is int and 0 <= row[k] < 2**64
                for k in ('count','nanoseconds','nestedLogicalGuardNanoseconds')), 'Invalid guard counters')
        if row['category'] in ('entryGuard','environmentGuard','osSnapshot','outerNativeFault'):
            require(row['count'] > 0, 'Missing actual entry guard observations')
        if row['category'].startswith('wire'):
            require(row['count'] == 0, 'Tiny-state check unexpectedly used transport')
    return value
