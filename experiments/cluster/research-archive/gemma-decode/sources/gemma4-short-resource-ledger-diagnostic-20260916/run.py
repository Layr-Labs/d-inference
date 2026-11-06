"""Run only after a root compiler grant; preserves the original failing assertion."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

BASE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify():
    value = json.loads((BASE / 'inputs.json').read_text())
    for row in value['files']:
        if sha(Path(row['path'])) != row['sha256']:
            raise ValueError('Diagnostic input changed: ' + row['path'])
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    value = verify(); old = Path(value['failedOutput']); checks = Path(value['qualifiedChecks'])
    sys.path.insert(0, str(checks))
    spec = importlib.util.spec_from_file_location('qualified_metadata', checks / 'run.py')
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    prior = json.loads((old / 'source-snapshot.json').read_text()); helper.verify_snapshot(prior)
    output = args.output.resolve(); output.mkdir(mode=0o700, parents=False, exist_ok=False)
    (output / 'module-cache').mkdir(mode=0o700)
    argv = json.loads((old / 'compile.json').read_text())['argv']
    original = value['originalFixture']; replacement = str(BASE / 'proposed/Gemma4ShortBudgetCheck.swift')
    if argv.count(original) != 1: raise ValueError('Exact failed fixture missing')
    argv = [replacement if item == original else item for item in argv]
    argv[argv.index('-module-cache-path') + 1] = str(output / 'module-cache')
    binary = output / 'diagnostic-check'; argv[argv.index('-o') + 1] = str(binary)
    try:
        helper.run_owned(argv, output, 'compile', 60); verify(); helper.verify_snapshot(prior)
        fixture = json.loads((old / 'fixture.json').read_text())['argv']; fixture[0] = str(binary)
        helper.run_owned(fixture, output, 'fixture', 10)
    finally:
        verify(); helper.verify_snapshot(prior)
        (output / 'binding.json').write_text(json.dumps({'fixtureSHA256': sha(Path(replacement)),
            'originalAssertionUnchanged': True, 'runtimeUnchanged': True, 'sourceUnchanged': True,
            'nativeOrModelExecuted': False, 'priorFailure': str(old)}, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
