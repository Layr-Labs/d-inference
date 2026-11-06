import hashlib
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
PREVIOUS = HERE.parent / 'distributed-http-terminal-delivery-integration-plan/prepare-private.py'
spec = importlib.util.spec_from_file_location('source_inventory', PREVIOUS)
prior = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prior)
sys.path.insert(0, str(PACKAGE / 'PrivateChecks'))
from check_process import run_owned


def save(name, value):
    (HERE / name).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def main():
    print('Preparation PID ' + str(os.getpid()), flush=True)
    WORKSPACE.mkdir(exist_ok=False)
    closure = prior.closure(MAIN)
    before = prior.inventory(MAIN)
    save('main-before.json', before)
    copies = []
    for index, relative in enumerate(closure):
        destination = WORKSPACE / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        copies.append(run_owned(['/bin/cp', '-cR', str(MAIN / relative), str(destination)], HERE, 'copy-' + str(index), 60))
    if prior.inventory(WORKSPACE) != before or prior.inventory(MAIN) != before:
        raise ValueError('Source/dependency clone changed')
    state = WORKSPACE / 'provider-swift/.build/workspace-state.json'
    (HERE / 'workspace-state-original.json').write_bytes(state.read_bytes())
    state.write_text(json.dumps(prior.replace_paths(json.loads(state.read_text()), str(MAIN), str(WORKSPACE)), indent=2) + '\n')
    preserved = []
    for cache in sorted((WORKSPACE / 'provider-swift/.build').glob('*/debug/ModuleCache')):
        target = HERE / 'preserved-path-bound-cache' / cache.relative_to(WORKSPACE / 'provider-swift/.build')
        target.parent.mkdir(parents=True, exist_ok=True)
        cache.rename(target)
        preserved.append({'source': str(cache), 'preserved': str(target)})
    run_owned([sys.executable, str(PACKAGE / 'stage_overlay.py'), '--workspace', str(WORKSPACE)], HERE, 'stage-overlay', 20)
    after = prior.inventory(WORKSPACE)
    expected = dict(before)
    for item in json.loads((WORKSPACE / 'quota-rotation-overlay.json').read_text())['files']:
        expected[item['path']] = {'sha256': item['sha256']}
    expected['provider-swift/Package.swift'] = {'sha256': prior.sha(WORKSPACE / 'provider-swift/Package.swift')}
    if after != expected or prior.inventory(MAIN) != before:
        raise ValueError('Unexpected source change beyond guarded overlay')
    save('candidate-before-1.json', after)
    save('preparation.json', {'workspace': str(WORKSPACE), 'main': str(MAIN), 'sourceDependencyFiles': len(before),
        'candidateSourceDependencyFiles': len(after), 'packageManifestSHA256': prior.sha(PACKAGE / 'manifest.json'),
        'inventoryHelperSHA256': prior.sha(PREVIOUS), 'candidateSnapshotSHA256': prior.sha(HERE / 'candidate-before-1.json'),
        'copyProcesses': copies, 'pathBoundCachesPreserved': preserved, 'mainUnchanged': True, 'compilerRun': False})
    print(json.dumps({'preparationSHA256': prior.sha(HERE / 'preparation.json'), 'candidateFiles': len(after)}), flush=True)


if __name__ == '__main__':
    main()
