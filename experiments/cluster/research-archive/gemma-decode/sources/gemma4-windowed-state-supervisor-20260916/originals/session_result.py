"""Closed result contract for actual tiny Qwen trunks and shared transactions."""
import math
from binding_common import fields, integer, parse, pin, require, same

REMOTE = '/Users/developer/DarkbloomDev/qwen-target-session-check-20260915'
NATIVE = '37783e2fdbe33022dd56752b6a14f25873515c3f77d1b15f9c4c28918be76960'
BUNDLE = '43e381343aff5fe3d670967a56f712139fb672bbbead3c3e2762131ca5f8cb2a'
SOURCE = '32fdc7a79171bba7f97a8434fdec48004875fd4d90f848d3488da6bd974b7ffe'
METALLIB = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
PAGED = '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'
BASE_CASES = ['actual-trunk-keep-0-and-next-decode', 'actual-trunk-keep-1-and-next-decode',
    'actual-trunk-keep-2-and-next-decode', 'actual-mismatching-draft-rollback-and-next-decode',
    'actual-progressive-client-stop', 'actual-progressive-continue', 'actual-one-step-output-limit']
FAILURE_CASES = ['actual-' + name + '-retired' for name in ['owner-before-stage',
    'owner-after-two-stages', 'pending-snapshot', 'pending-decode', 'pending-finish',
    'commit-then-reject-prefix', 'seed-eos']]


def validate_result(raw):
    require(type(raw) is bytes and 0 < len(raw) <= 16384, 'Native result exceeds its bound')
    value = fields(parse(raw), 'fixture passed maximumLogitDifference stateComparison seedTokenID '
        'ordinaryTargetChosenDraftTokenID eosAfterSeedExercised resourceLedger sourceTensorCount '
        'sourceTensorBytes sourcePayloadSHA256 stageActiveTensorCounts sharedSessionTransactionExecuted '
        'registeredProfileExecuted mtpAssistantProposalExecuted bilateralWireVerification '
        'providerEligibilityEstablished', 'tiny Session result')
    same(value['fixture'], 'fabricated-full-source-two-real-stages', 'actual fixture')
    same(value['stateComparison'], 'exact-named-state-hashes-after-reconcile-and-next-decode', 'state comparison')
    seed = integer(value['seedTokenID'], 'seed', 0, 127)
    draft = integer(value['ordinaryTargetChosenDraftTokenID'], 'target-selected draft', 0, 127)
    same(value['eosAfterSeedExercised'], draft != seed, 'actual conditional EOS')
    expected = BASE_CASES + (['actual-progressive-eos'] if draft != seed else []) + FAILURE_CASES
    same(value['passed'], expected, 'complete ordered native cases')
    for name, wanted in [('sharedSessionTransactionExecuted', True), ('registeredProfileExecuted', False),
            ('mtpAssistantProposalExecuted', False), ('bilateralWireVerification', False),
            ('providerEligibilityEstablished', False)]:
        same(value[name], wanted, name)
    difference = value['maximumLogitDifference']
    require(type(difference) in (int, float) and math.isfinite(difference)
            and 0 <= difference <= 0.00001, 'Logit error exceeds native fixture tolerance')
    count = integer(value['sourceTensorCount'], 'source count', 1, 4096)
    integer(value['sourceTensorBytes'], 'source bytes', 1, 64*1024**2)
    pin(value['sourcePayloadSHA256'])
    stages = value['stageActiveTensorCounts']
    require(type(stages) is list and len(stages) == 2, 'Two actual stage inventories required')
    require(sum(integer(v, 'stage tensors', 1, 4096) for v in stages) == count,
            'Disjoint stage source coverage differs')
    ledger = fields(value['resourceLedger'], 'maximumTokens chunkTokens simultaneousPairs '
        'perPairLogicalStateAndBoundaryBytes roundedStateAndBoundaryBytes fusionBytes '
        'comparisonNativeBytes comparisonHostBytes transactionNativeBytes transactionHostBytes '
        'wholeProcessBound', 'fixture ledger')
    for name, wanted in [('maximumTokens', 9), ('chunkTokens', 2), ('simultaneousPairs', 2),
            ('perPairLogicalStateAndBoundaryBytes', 108808), ('fusionBytes', 0),
            ('comparisonHostBytes', 1024), ('wholeProcessBound', False)]:
        same(ledger[name], wanted, name)
    # Native rounding is runtime-derived, not replaced with a host estimate.
    integer(ledger['roundedStateAndBoundaryBytes'], 'rounded state', 2*108808, 256*1024**2)
    integer(ledger['comparisonNativeBytes'], 'comparison native', 4*128*4, 256*1024**2)
    for name in ['transactionNativeBytes', 'transactionHostBytes']:
        values = ledger[name]
        require(type(values) is list and len(values) == 2, 'Two rank allowances required')
        for item in values: integer(item, name, 0, 256*1024**2)
    return value
