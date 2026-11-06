"""Foundation-only regression; root must grant the compiler slot first."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

from verify import BASE, pin, verify


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    inputs = verify(); old = Path(inputs['failedOutput']); checks = Path(inputs['qualifiedChecks'])
    sys.path.insert(0, str(checks))
    spec = importlib.util.spec_from_file_location('qualified_stage_metadata', checks / 'run.py')
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    prior = json.loads((old / 'source-snapshot.json').read_text()); helper.verify_snapshot(prior)
    argv = json.loads((old / 'compile.json').read_text())['argv']
    for before, after in inputs['foundationReplacements'].items():
        if argv.count(before) != 1:
            raise ValueError('Exact failed source missing: ' + before)
        argv = [str(BASE / after) if item == before else item for item in argv]
    additions = [str(BASE / value) for value in inputs['foundationAdditions']]
    argv[argv.index('-o'):argv.index('-o')] = additions
    sources = [item for item in argv if item.endswith('.swift')]
    if len(sources) != 36 or len(set(sources)) != len(sources):
        raise ValueError('Unexpected corrected Foundation closure')
    output = args.output.resolve(); output.mkdir(mode=0o700, parents=False, exist_ok=False)
    (output / 'module-cache').mkdir(mode=0o700)
    binary = output / 'gemma-dtype-resource-check'
    argv[argv.index('-module-cache-path') + 1] = str(output / 'module-cache')
    argv[argv.index('-o') + 1] = str(binary)
    snapshot = {'swiftSources': sources, 'files': [pin(Path(path)) for path in sources],
        'correctionManifest': pin(BASE / 'manifest.json'), 'priorSnapshot': pin(old / 'source-snapshot.json')}
    (output / 'source-snapshot.json').write_text(json.dumps(snapshot, indent=2, sort_keys=True) + '\n')
    try:
        compiled = helper.run_owned(argv, output, 'compile', 60)
        verify(); helper.verify_snapshot(prior); helper.verify_snapshot(snapshot)
        fixture = json.loads((old / 'fixture.json').read_text())['argv']; fixture[0] = str(binary)
        executed = helper.run_owned(fixture, output, 'fixture', 10)
        result = json.loads((output / 'fixture.stdout').read_text())
        if (output / 'fixture.stderr').stat().st_size or any(result[key] for key in
                ['runtimeExecutionAuthorized', 'actualAllocatorBoundsObserved', 'modelConstructed', 'payloadRead']):
            raise ValueError('Unexpected native claim or fixture diagnostics')
    finally:
        verify(); helper.verify_snapshot(prior); helper.verify_snapshot(snapshot)
        (output / 'source-recheck.json').write_text(json.dumps({'sourceUnchanged': True,
            'originalLedgerAndBudgetAssertionUnchanged': True, 'modelOrGPUExecuted': False}, sort_keys=True) + '\n')
    receipt = {'compile': compiled, 'fixture': executed, 'acceptedCount': result['acceptedCount'],
        'refusedCount': result['refusedCount'], 'sourceUnchanged': True, 'modelOrGPUExecuted': False,
        'originalLedgerAndBudgetAssertionUnchanged': True}
    (output / 'checks.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'passed': True, 'accepted': result['acceptedCount'], 'refused': result['refusedCount']}, sort_keys=True))


if __name__ == '__main__':
    main()
