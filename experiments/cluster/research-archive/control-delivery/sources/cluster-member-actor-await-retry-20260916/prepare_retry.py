"""Grant-only two-file correction in the existing private build; never compiles."""
import argparse
import json
import os
from pathlib import Path
import sys
sys.dont_write_bytecode = True
import source_inventory as inventory
from guards import sha, save, verify_overlay, verify_failed_evidence
from inputs import BASE, SOURCE, FAILED, RETRY, OVERLAY_SHA, B_OVERLAY_SHA, ORIGINAL_SHA


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true', required=True)
    parser.parse_args()
    integration = verify_overlay(); verify_failed_evidence()
    workspace = FAILED / 'workspace'
    previous = json.loads((FAILED / 'preparation.json').read_text())
    before = json.loads((FAILED / 'source-before.json').read_text())
    failed_candidate = json.loads((FAILED / 'candidate-before.json').read_text())
    if (previous['workspace'] != str(workspace) or previous['source'] != str(SOURCE)
            or previous['wrapperManifestSHA256'] != ORIGINAL_SHA or previous['phase'] != 'swift'):
        raise ValueError('Prior preparation identity differs')
    if inventory.inventory(workspace) != failed_candidate or inventory.inventory(SOURCE) != before:
        raise ValueError('Original private or MAIN source/dependency inventory changed')
    corrected = dict(before)
    for row in integration['files']:
        corrected[row['path']] = {'sha256': row['proposedSHA256']}
    corrections = json.loads((BASE / 'integration.json').read_text())['files']
    changed = {path for path in failed_candidate if failed_candidate[path] != corrected.get(path)}
    if set(failed_candidate) != set(corrected) or changed != {row['path'] for row in corrections}:
        raise ValueError('Retry changes more than the two authorized sources')
    # Preserve the original preparation/inventories and failed attempt in place.
    # New receipt location contains the exact preimages and corrected inventory.
    RETRY.mkdir(mode=0o700, exist_ok=False)
    save(RETRY / 'source-before.json', before)
    save(RETRY / 'failed-candidate-before.json', failed_candidate)
    staged = []
    for row in corrections:
        destination = workspace / row['path']
        if destination.is_symlink() or sha(destination) != row['baseSHA256']:
            raise ValueError('Private correction preimage changed')
        backup = RETRY / 'originals' / row['path']
        backup.parent.mkdir(parents=True, exist_ok=True)
        with backup.open('xb') as stream:
            stream.write(destination.read_bytes())
        if sha(backup) != row['baseSHA256']:
            raise ValueError('Retained correction preimage differs')
        temporary = destination.with_name(destination.name + '.await-correction.new')
        with temporary.open('xb') as stream:
            stream.write((BASE / 'proposed' / row['path']).read_bytes())
            stream.flush(); os.fsync(stream.fileno())
        if sha(temporary) != row['proposedSHA256']:
            raise ValueError('Staged correction differs')
        staged.append((temporary, destination, row))
    for temporary, destination, row in staged:
        if destination.is_symlink() or sha(destination) != row['baseSHA256']:
            raise ValueError('Private source changed before replacement')
        os.replace(temporary, destination)
    if inventory.inventory(workspace) != corrected or inventory.inventory(SOURCE) != before:
        raise ValueError('Corrected private or MAIN source/dependency inventory differs')
    verify_overlay(); verify_failed_evidence()
    save(RETRY / 'candidate-before.json', corrected)
    receipt = dict(previous, wrapperManifestSHA256=sha(BASE / 'manifest.json'),
        overlayManifestSHA256=OVERLAY_SHA, nativeBManifestSHA256=B_OVERLAY_SHA,
        swiftIntegrationSHA256=sha(BASE / 'swift-integration.json'),
        actorAwaitIntegrationSHA256=sha(BASE / 'integration.json'),
        correctedSourcePaths=sorted(changed), failedPreparationSHA256=sha(FAILED / 'preparation.json'),
        retainedFailureInputSHA256=sha(BASE / 'failure-inputs.json'),
        sourceFiles=len(before), candidateFiles=len(corrected),
        inheritedPreparationReceipts=True, compilerRun=False,
        newWorkspaceCreated=False, workspacePathUnchanged=True,
        buildCacheReusedWithoutCopy=True, mainUnchanged=True)
    save(RETRY / 'preparation.json', receipt)
    print(json.dumps({'prepared': str(RETRY), 'workspace': str(workspace),
        'corrections': sorted(changed), 'candidateFiles': len(corrected), 'compilerRun': False}, sort_keys=True))


if __name__ == '__main__':
    main()
