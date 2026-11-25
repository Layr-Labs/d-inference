"""Grant-only derivative of the reviewed member source/cache preparation."""
import argparse
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True
import source_inventory as inventory
from check_process import run_owned
from context import BASE, SOURCE, sha, save, verify

def main():
    p = argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    integration = verify()
    output = args.output.resolve(); output.mkdir(mode=0o700, exist_ok=False)
    workspace = output / 'workspace'; workspace.mkdir(mode=0o700)
    closure = inventory.closure(SOURCE); before = inventory.inventory(SOURCE)
    save(output / 'source-before.json', before)
    copies = []
    for index, relative in enumerate(closure):
        destination = workspace / relative; destination.parent.mkdir(parents=True, exist_ok=True)
        copies.append(run_owned(['/bin/cp', '-cR', str(SOURCE / relative), str(destination)], output, 'copy-' + str(index), 120))
    if inventory.inventory(workspace) != before or inventory.inventory(SOURCE) != before or inventory.closure(workspace) != closure:
        raise ValueError('Source/cache clone differs; retained')
    state = workspace / 'provider-swift/.build/workspace-state.json'
    with (output / 'workspace-state-original.json').open('xb') as stream: stream.write(state.read_bytes())
    state.write_text(json.dumps(inventory.replace_paths(json.loads(state.read_text()), str(SOURCE), str(workspace)), indent=2) + '\n')
    with (output / 'workspace-state-relocated.json').open('xb') as stream: stream.write(state.read_bytes())
    caches = []
    for cache in sorted((workspace / 'provider-swift/.build').glob('*/debug/ModuleCache')):
        target = output / 'preserved-path-bound-cache' / cache.relative_to(workspace / 'provider-swift/.build')
        target.parent.mkdir(parents=True, exist_ok=True); cache.rename(target); caches.append(str(target.relative_to(output)))
    expected = dict(before)
    for row in integration['files']:
        destination = workspace / row['path']; destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(Path(row['sourcePath']).read_bytes())
        expected[row['path']] = {'sha256': row['proposedSHA256']}
    if inventory.inventory(workspace) != expected or inventory.inventory(SOURCE) != before:
        raise ValueError('Unexpected source delta; retained')
    verify(); save(output / 'candidate-before.json', expected)
    save(output / 'preparation.json', {'workspace': str(workspace), 'source': str(SOURCE),
        'wrapperManifestSHA256': sha(BASE / 'manifest.json'), 'integrationSHA256': sha(BASE / 'integration.json'),
        'localPackageClosure': closure, 'sourceFiles': len(before), 'candidateFiles': len(expected),
        'privateWorkspaceStateSHA256': sha(state), 'copies': copies, 'preservedCaches': caches, 'compilerRun': False})

if __name__ == '__main__': main()
