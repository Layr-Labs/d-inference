import importlib.util
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
PACKAGE = HERE.parent / 'cluster-session-quota-rotation-draft-20260915'
MAIN = Path('/Users/developer/DarkbloomDev/d-inference')
WORKSPACE = HERE / 'workspace'
spec = importlib.util.spec_from_file_location('source_inventory', HERE.parent / 'distributed-http-terminal-delivery-integration-plan/prepare-private.py')
prior = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prior)
sys.path.insert(0, str(PACKAGE / 'PrivateChecks'))
from check_process import run_owned


def main():
    print('Rotation sequence PID ' + str(os.getpid()), flush=True)
    before = json.loads((HERE / 'candidate-before-2.json').read_text())
    original = json.loads((HERE / 'main-before.json').read_text())
    def recheck():
        if prior.inventory(WORKSPACE) != before or prior.inventory(MAIN) != original:
            raise ValueError('Candidate or MAIN source/dependency bytes changed')
    recheck()
    out = HERE / 'sequence-2'
    out.mkdir(mode=0o700, exist_ok=False)
    children, cases = out / 'children', out / 'cases'
    steps = [
        ('provider-tests', ['swift', 'test', '-j', '2', '--disable-automatic-resolution', '--disable-build-manifest-caching',
             '--filter', 'Distributed|distributedLocal|distributedHTTP|HTTPOrigin|httpOrigin|clusterStatus|ClusterStatus'], 900),
        ('driver-build', ['swift', 'build', '-j', '2', '--disable-automatic-resolution', '--disable-build-manifest-caching',
             '--product', 'DistributedRotationOwnerCheck'], 900),
        ('children-build', [sys.executable, str(PACKAGE / 'PrivateChecks/build_children.py'), '--checkout', str(WORKSPACE),
             '--output', str(children)], 360),
        ('actual-owner-cases', [sys.executable, str(PACKAGE / 'PrivateChecks/run_cases.py'),
             '--driver', str(WORKSPACE / 'provider-swift/.build/debug/DistributedRotationOwnerCheck'),
             '--children', str(children), '--output', str(cases)], 360),
    ]
    receipts = []
    os.chdir(WORKSPACE / 'provider-swift')
    for name, command, timeout in steps:
        recheck()
        print('Starting ' + name, flush=True)
        try:
            receipts.append(run_owned(command, out, name, timeout))
        finally:
            recheck()
            (out / (name + '-source-recheck.json')).write_text(json.dumps({'candidateUnchanged': True, 'mainUnchanged': True,
                'sourceDependencyCount': len(before)}, indent=2) + '\n')
        print('Completed ' + name, flush=True)
    (out / 'checks.json').write_text(json.dumps({'passed': True, 'steps': receipts, 'sourceDependencyPinsUnchanged': True,
        'nativeModelExecuted': False, 'mainMutated': False}, indent=2) + '\n')


if __name__ == '__main__':
    main()
