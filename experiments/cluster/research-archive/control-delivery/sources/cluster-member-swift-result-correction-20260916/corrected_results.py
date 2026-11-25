"""Require actual Swift Testing pass lines, not discovery/start or compiler text."""
import re
from context import NATIVE_PAIR_METHODS, SWIFT_FILTER

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
    if re.search(r'(?m)^✘ ', text):
        raise ValueError('Swift Testing failure/issue record present')
    summaries = re.findall(r'(?m)^✔ Test run with (\d+) tests in (\d+) suites passed after \d+(?:\.\d+)? seconds\.$', text)
    if len(summaries) != 1:
        raise ValueError('Unique successful Swift Testing summary absent')
    for name in MEMBER_METHODS + NATIVE_PAIR_METHODS:
        if len(re.findall(r'(?m)^✔ Test ' + re.escape(name) + r'\(\) passed after [^\n]+$', text)) != 1:
            raise ValueError('Required passed member/native/CLI case absent or repeated: ' + name)
    # Swift Testing reports one aggregate completion only after both cases finish.
    title = '"Real WebSocket requires explicit member acknowledgment"'
    aggregate = re.compile(r'^✔ Test ' + re.escape(title)
        + r' with 2 test cases passed after \d+(?:\.\d+)? seconds\.$')
    lines = text.splitlines()
    relevant = [(i, line) for i, line in enumerate(lines) if title in line]
    start = '◇ Test ' + title + ' started.'
    cases = ['◇ Test case passing 1 argument acknowledge → ' + value
             + ' to ' + title + ' started.' for value in ('false', 'true')]
    starts = [i for i, line in relevant if line == start]
    case_positions = [[i for i, line in relevant if line == case] for case in cases]
    completions = [i for i, line in relevant if aggregate.fullmatch(line)]
    if (len(relevant) != 4 or len(starts) != 1 or len(completions) != 1
            or any(len(positions) != 1 for positions in case_positions)
            or not all(starts[0] < positions[0] < completions[0] for positions in case_positions)):
        raise ValueError('Exact two-case real WebSocket negotiation completion absent or repeated')
    count, suites = map(int, summaries[0])
    if count < len(MEMBER_METHODS) + len(NATIVE_PAIR_METHODS) + 1:
        raise ValueError('Swift Testing completion count is incomplete')
    return {'testsPassed': count, 'suitesPassed': suites,
            'parameterizedMemberCasesPassed': 2, 'parameterizedMemberCaseValues': [False, True], 'filter': SWIFT_FILTER, 'realSocketCasesIncluded': True,
            'requiredMemberAndCLIMethodsPassed': len(MEMBER_METHODS) + 1,
            'nativePairMethodsPassed': len(NATIVE_PAIR_METHODS),
            'nativePairPassedMethods': list(NATIVE_PAIR_METHODS)}
