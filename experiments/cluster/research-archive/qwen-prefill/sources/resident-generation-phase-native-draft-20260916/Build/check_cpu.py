"""Root-granted Foundation/temporary-file checks only; no model/native worker."""
import json
import os
import sys
from build_inputs import BASE, DRAFT, authority, sha
from owned_process import invoke_controller


def main():
    attempt, = sys.argv[1:]
    if not attempt.isdecimal() or not 1 <= int(attempt) <= 99:
        raise ValueError('Expected fresh numeric CPU attempt')
    authority()
    out = BASE / ('cpu-' + attempt)
    out.mkdir(mode=0o700)
    runtime = DRAFT / 'proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    worker = DRAFT / 'proposed/libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker'
    tests = DRAFT / 'Tests'
    common = [runtime / ('QwenGenerationPhase' + name + '.swift') for name in ['Observation', 'Budget', 'Recorder', 'Hook']]
    common += [tests / name for name in ['FixtureSupport.swift', 'ExactFrame.swift']]
    encoding = common + [runtime / ('QwenGenerationPhase' + name + '.swift') for name in ['HostAllocation', 'JSON', 'Encoding']]
    encoding += [tests / name for name in ['ExactSessionIdentity.swift', 'ExactFinishReason.swift', 'ExactGenerationResult.swift', 'ExactPrefillSummary.swift', 'EncodingCheck.swift']]
    encoding += [worker / 'ResidentEvidenceSink.swift']
    commands = []
    for name, sources, groups in [('phases', common + [tests / 'PhaseCheck.swift'], 11), ('encoding', encoding, 5)]:
        binary = out / name
        commands.append((name + '-compile', ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-j', '2',
            '-parse-as-library', '-D', 'QWEN_GENERATION_PHASE_FIXTURE', *map(str, sources), '-o', str(binary)], 90, None))
        commands.append((name + '-run', [str(binary)], 30, groups))
    commands.append(('phase-schema', ['/usr/bin/python3', '-B', str(tests / 'test_phase_schema.py')], 30, None))
    result = dict(steps=[], compilerJobsMaximum=2, modelOrRemoteExecuted=False, passed=False,
        frozenSourceManifestSHA256=sha(DRAFT / 'manifest.json'))
    try:
        for name, argv, timeout, groups in commands:
            step = dict(name=name, argv=argv); result['steps'].append(step)
            with (out / (name + '.stdout')).open('xb') as stdout, (out / (name + '.stderr')).open('xb') as stderr:
                invoke_controller(argv, stdout, stderr, step, timeout=timeout)
            if step.get('exitCode') != 0 or not step.get('reaped') or not step.get('groupAbsent'):
                raise RuntimeError('CPU check failed or owned child remains: ' + name)
            if groups is not None and json.loads((out / (name + '.stdout')).read_bytes())['count'] != groups:
                raise RuntimeError('CPU group completion differs')
            (out / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
        authority()
        if sha(DRAFT / 'manifest.json') != result['frozenSourceManifestSHA256']:
            raise RuntimeError('Frozen source changed during CPU checks')
        result['passed'] = True
    except BaseException as error:
        result['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        (out / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(passed=True, foundationGroups=16, pythonMethods=4)))


if __name__ == '__main__':
    os.umask(0o077)
    main()
