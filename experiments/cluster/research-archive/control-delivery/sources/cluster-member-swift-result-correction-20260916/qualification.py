"""Qualify only retained raw successful execution; launch no process."""
import json
import re
from context import PACKAGE, RETRY, SWIFT_FILTER, UPSTREAM_SHA, sha, verify_preparation
from corrected_results import validate_swift_results


def expected_receipt():
    workspace, before, candidate = verify_preparation()
    bound = json.loads((PACKAGE / 'raw-inputs.json').read_text())
    if bound['root'] != str(RETRY) or len(bound['files']) != 7:
        raise ValueError('Unexpected raw input closure')
    for row in bound['files']:
        path = RETRY / row['path']
        if (not path.is_file() or path.is_symlink() or path.stat().st_size != row['sizeBytes']
                or sha(path) != row['sha256']):
            raise ValueError('Retained successful-run evidence changed: ' + str(path))
    actual = RETRY / 'swift-tests-2'
    execution = json.loads((actual / 'execution.json').read_text())
    command = ['swift', 'test', '-j', '2', '--disable-automatic-resolution',
               '--disable-build-manifest-caching', '--filter', SWIFT_FILTER]
    if (execution.get('argv') != command or execution.get('exitCode') != 0
            or execution.get('reaped') is not True or execution.get('groupAbsent') is not True
            or execution.get('timedOut') is not False or execution.get('killedOwnedGroup') is not False
            or execution.get('timeoutSeconds') != 900 or execution.get('diagnosticLimitBytes') != 4194304):
        raise ValueError('Matching natural successful Swift child required')
    recheck = json.loads((actual / 'source-recheck.json').read_text())
    if recheck != {'mainUnchanged': True, 'sourcePinsUnchanged': True}:
        raise ValueError('Actual successful child lacks the unchanged-source receipt')
    text = (actual / 'execution.stdout').read_text() + '\n' + (actual / 'execution.stderr').read_text()
    details = validate_swift_results(text)
    # Bind this one retained run, including every aggregate test and suite line.
    completed = re.findall(r'(?m)^✔ Test (?!run with )(.+?) (?:with [1-9]\d* test cases )?passed after \d+(?:\.\d+)? seconds\.$', text)
    suites = re.findall(r'(?m)^✔ Suite (.+?) passed after \d+(?:\.\d+)? seconds\.$', text)
    if (details['testsPassed'] != 78 or details['suitesPassed'] != 12
            or len(completed) != 78 or len(set(completed)) != 78
            or len(suites) != 12 or len(set(suites)) != 12):
        raise ValueError('Retained 78-test/12-suite completion coverage differs')
    return {'passed': True, 'phase': 'retained-swift-result-qualification', 'details': details,
        'actualChildPID': execution['pid'], 'actualChildElapsedSeconds': execution['elapsedSeconds'],
        'executionSHA256': sha(actual / 'execution.json'), 'rawInputsSHA256': sha(PACKAGE / 'raw-inputs.json'),
        'candidateSourceSHA256': sha(RETRY / 'candidate-before.json'),
        'mainSourceSHA256': sha(RETRY / 'source-before.json'),
        'candidateFileCount': len(candidate), 'mainFileCount': len(before), 'workspace': str(workspace),
        'originalWrapperManifestSHA256': UPSTREAM_SHA, 'correctionManifestSHA256': sha(PACKAGE / 'manifest.json'),
        'correctedParserSHA256': sha(PACKAGE / 'corrected_results.py'),
        'retainedImmediatePostChildSourceRecheckSHA256': sha(actual / 'source-recheck.json'),
        'currentWholeTreesRehashed': False, 'testOrCompilerRerun': False, 'candidateChanged': False,
        'originalParserOutcome': 'refused actual parameterized completion grammar',
        'allAggregateTestCompletions': 78, 'allSuiteCompletions': 12,
        'ownerKeyGrantQualified': False, 'modelOrRemoteExecuted': False}
