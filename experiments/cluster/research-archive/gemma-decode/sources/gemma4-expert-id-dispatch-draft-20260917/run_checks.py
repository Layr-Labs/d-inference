#!/usr/bin/env python3
"""Future root-only Foundation qualification. No MLX or model invocation."""
import contextlib
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit() or int(sys.argv[1]) < 1:
        raise RuntimeError('expected one positive attempt number')
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    for member in manifest['members']:
        path = ROOT / member['path']
        if not path.is_file() or path.stat().st_size != member['bytes'] or sha(path) != member['sha256']:
            raise RuntimeError('source member changed: ' + member['path'])
    inputs = json.loads((ROOT / 'source-inputs.json').read_text())
    helper = next(row for row in inputs['sources'] if row['role'] == 'owned_runner')
    helper_path = Path(helper['path'])
    if sha(helper_path) != helper['sha256']:
        raise RuntimeError('owned runner source changed')
    spec = importlib.util.spec_from_file_location('expert_owned_runner', helper_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    output = ROOT / ('checks-' + sys.argv[1])
    output.mkdir(mode=0o700)
    binary = output / 'ExpertDispatchChecks'
    compile_argv = ['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-j', '2',
        '-O', '-module-cache-path', str(output / 'module-cache'),
        str(ROOT / 'Sources/ExpertIDOwnership.swift'), str(ROOT / 'Sources/ExpertDispatchPlan.swift'),
        str(ROOT / 'Tests/ExpertDispatchChecks.swift'), '-o', str(binary)]
    aggregate = {'schema': 'expert_id_dispatch_foundation_run_v1', 'steps': [], 'passed': False,
        'sourceManifestSHA256': sha(ROOT / 'manifest.json'), 'nativeModelExecuted': False}
    try:
        for name, argv, timeout in [('compile', compile_argv, 90), ('checks', [str(binary)], 15)]:
            receipt = {'name': name, 'argv': argv}
            aggregate['steps'].append(receipt)
            started = time.monotonic()
            try:
                with (output / (name + '.stdout')).open('xb') as stdout, \
                    (output / (name + '.stderr')).open('xb') as stderr, \
                    (output / (name + '.runner.log')).open('x') as log, contextlib.redirect_stdout(log):
                    module.invoke_controller(argv, stdout, stderr, receipt, timeout=timeout)
            finally:
                receipt['elapsedSeconds'] = time.monotonic() - started
                (output / (name + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
            if receipt.get('exitCode') != 0 or not receipt.get('reaped') or not receipt.get('groupAbsent'):
                raise RuntimeError('owned child did not pass: ' + name)
        raw = (output / 'checks.stdout').read_bytes()
        if len(raw) > 65536 or (output / 'checks.stderr').stat().st_size:
            raise RuntimeError('unexpected check output')
        result = json.loads(raw)
        expected = json.loads((ROOT / 'expected-checks.json').read_text())
        if result != expected:
            raise RuntimeError('Foundation group completion differs')
        aggregate['checks'] = result
        aggregate['binarySHA256'] = sha(binary)
        aggregate['passed'] = True
    finally:
        (output / 'receipt.json').write_text(json.dumps(aggregate, indent=2) + '\n')
    print(json.dumps({'passed': True, 'groups': len(aggregate['checks']['groups']),
        'receipt': str(output / 'receipt.json')}))


if __name__ == '__main__':
    main()
