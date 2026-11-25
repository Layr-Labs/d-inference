"""Require actual Swift Testing pass lines, not discovery/start or compiler text."""
import re
from inputs import NATIVE_PAIR_METHODS, SWIFT_FILTER

MEMBER_METHODS = (
    'legacyOmissionAndMemberInventorySurviveRawAttestation',
    'explicitAckRejectsWrongNonceRoleLateAndDuplicate',
    'staleNegotiationTimerCannotRefuseReplacement',
    'clientDoesNotPublishConnectedBeforeAckAndRefusesOldAckOnReconnect',
    'directLoadPrefetchInferenceAndDesiredEventsNeverStartWork',
    'emptyCapacityAndNoPersistenceOrBackgroundLoad',
    'disconnectDropsConnectionGenerationBeforeReconnect',
    'acceptedLeaderControlLossLatchesStopBeforeReconnect',
    'unacknowledgedAndCancelledRegistrationWaitsRefuse',
    'memberRoleSelectionAndExplicitCoordinatorParseWithoutIO',
)


def validate_swift_results(text):
    summaries = re.findall(r'(?m)^✔ Test run with (\d+) tests?[^\n]*passed[^\n]*$', text)
    if len(summaries) != 1:
        raise ValueError('Unique successful Swift Testing summary absent')
    for name in MEMBER_METHODS + NATIVE_PAIR_METHODS:
        if len(re.findall(r'(?m)^✔ Test ' + re.escape(name) + r'\(\) passed after [^\n]+$', text)) != 1:
            raise ValueError('Required passed member/native/CLI case absent or repeated: ' + name)
    # This existing parameterized test has a display name, so Swift Testing
    # reports that title rather than the source function identifier.
    if len(re.findall(r'(?m)^✔ Test "Real WebSocket requires explicit member acknowledgment" passed after [^\n]+$', text)) != 1:
        raise ValueError('Required real WebSocket member negotiation completion absent')
    count = int(summaries[0])
    if count < len(MEMBER_METHODS) + len(NATIVE_PAIR_METHODS) + 1:
        raise ValueError('Swift Testing completion count is incomplete')
    return {'testsPassed': count, 'filter': SWIFT_FILTER, 'realSocketCasesIncluded': True,
            'requiredMemberAndCLIMethodsPassed': len(MEMBER_METHODS) + 1,
            'nativePairMethodsPassed': len(NATIVE_PAIR_METHODS),
            'nativePairPassedMethods': list(NATIVE_PAIR_METHODS)}
