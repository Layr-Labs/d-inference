"""Explicit grant-only Go source materialization; no compile or cache clone."""
import argparse
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True
from guards import save, sha, verify_overlay, go_snapshot, source_for, verify_go
from inputs import BASE, SOURCE, OVERLAY_SHA, B_OVERLAY_SHA, CORRECTION_SHA


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--phase', choices=['go'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    verify_overlay()
    output = args.output.resolve()
    if output.parent != BASE.parent or output == BASE:
        raise ValueError('Expected a fresh private research sibling')
    snapshot = go_snapshot()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    workspace = output / 'workspace'; workspace.mkdir(mode=0o700)
    save(output / 'source-before.json', snapshot)
    for row in snapshot['files']:
        destination = workspace / row['path']; destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('xb') as stream:
            stream.write(source_for(row['path']).read_bytes())
    verify_overlay(); verify_go(snapshot, workspace)
    receipt = {'phase': 'go', 'sourceFiles': len(snapshot['files']), 'packages': snapshot['packages'],
               'workspace': str(workspace), 'source': str(SOURCE), 'overlayManifestSHA256': OVERLAY_SHA,
               'nativeOverlayManifestSHA256': B_OVERLAY_SHA, 'correctionManifestSHA256': CORRECTION_SHA,
               'sourceInventorySHA256': sha(output / 'source-before.json'),
               'mainUnchanged': True, 'compilerRun': False}
    save(output / 'preparation.json', receipt)
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    main()
