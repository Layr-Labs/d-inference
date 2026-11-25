"""Explicit grant-only private source/cache materialization; never compiles."""
import argparse
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True
import source_inventory as inventory
from check_process import run_owned
from guards import save, sha, verify_overlay, go_snapshot, source_for, verify_go
from inputs import SOURCE, OVERLAY, OVERLAY_SHA

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=['go', 'swift'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    integration = verify_overlay()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    workspace = output / 'workspace'; workspace.mkdir(mode=0o700)
    if args.phase == 'go':
        snapshot = go_snapshot()
        save(output / 'source-before.json', snapshot)
        for row in snapshot['files']:
            destination = workspace / row['path']; destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open('xb') as stream:
                stream.write(source_for(row['path']).read_bytes())
        verify_overlay(); verify_go(snapshot, workspace)
        receipt = {'phase': 'go', 'sourceFiles': len(snapshot['files']), 'packages': snapshot['packages']}
    else:
        closure = inventory.closure(SOURCE)
        before = inventory.inventory(SOURCE)
        save(output / 'source-before.json', before)
        receipts = []
        for index, relative in enumerate(closure):
            destination = workspace / relative; destination.parent.mkdir(parents=True, exist_ok=True)
            receipts.append(run_owned(['/bin/cp', '-cR', str(SOURCE / relative), str(destination)], output, 'copy-' + str(index), 120))
        if inventory.inventory(workspace) != before or inventory.inventory(SOURCE) != before or inventory.closure(workspace) != closure:
            raise ValueError('Source/cache clone differs; retained')
        state = workspace / 'provider-swift/.build/workspace-state.json'
        with (output / 'workspace-state-original.json').open('xb') as stream:
            stream.write(state.read_bytes())
        state.write_text(json.dumps(inventory.replace_paths(json.loads(state.read_text()), str(SOURCE), str(workspace)), indent=2) + '\n')
        caches = []
        for cache in sorted((workspace / 'provider-swift/.build').glob('*/debug/ModuleCache')):
            target = output / 'preserved-path-bound-cache' / cache.relative_to(workspace / 'provider-swift/.build')
            target.parent.mkdir(parents=True, exist_ok=True); cache.rename(target)
            caches.append(str(target.relative_to(output)))
        expected = dict(before)
        for row in integration['files']:
            if not row['path'].startswith('provider-swift/'):
                continue
            destination = workspace / row['path']; destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((OVERLAY / 'proposed' / row['path']).read_bytes())
            expected[row['path']] = {'sha256': row['proposedSHA256']}
        if inventory.inventory(workspace) != expected or inventory.inventory(SOURCE) != before:
            raise ValueError('Unexpected source delta; retained')
        verify_overlay()
        save(output / 'candidate-before.json', expected)
        receipt = {'phase': 'swift', 'sourceFiles': len(before), 'candidateFiles': len(expected),
                   'localPackageClosure': closure, 'copies': receipts, 'preservedCaches': caches,
                   'privateWorkspaceStateSHA256': sha(state)}
    receipt.update(workspace=str(workspace), source=str(SOURCE), overlayManifestSHA256=OVERLAY_SHA,
                   mainUnchanged=True, compilerRun=False)
    save(output / 'preparation.json', receipt)
    print(json.dumps(receipt, sort_keys=True))

if __name__ == '__main__':
    main()
