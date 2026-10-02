"""Preserve the canonical binary and all nine replaced native source preimages."""
import json
import os
import shutil
from pathlib import Path
from retry_inputs import BASE, NUMERICAL, WORKSPACE, SCRATCH, sha, expected
from verify_retry import verify
from bind_activation import activation

def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')

def main():
    output = BASE / 'preparation-5'
    output.mkdir(mode=0o700)
    receipt = dict(status='failed', compilerExecuted=False, cacheCopied=False, remoteExecuted=False)
    try:
        receipt['before'] = verify(before=True, require_snapshots=False)
        native = SCRATCH / 'arm64-apple-macosx/release/darkbloom-cluster-worker'
        bound = activation()
        digest = bound['canonicalNativeSHA256']
        if native.is_symlink() or sha(native) != digest:
            raise ValueError('Actual canonical native differs')
        # Only the actual canonical binary is preserved; no build cache is cloned.
        with native.open('rb') as source, (output / 'darkbloom-cluster-worker.canonical4').open('xb') as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
        if sha(output / 'darkbloom-cluster-worker.canonical4') != digest:
            raise ValueError('Preserved binary differs')
        rows = json.loads((BASE / 'integration.json').read_bytes())['files']
        for row in rows:
            destination = WORKSPACE / row['path']
            if row['preimageSHA256'] is None:
                if destination.exists() or destination.is_symlink():
                    raise ValueError('New numerical source destination already exists')
            else:
                if destination.is_symlink() or sha(destination) != row['preimageSHA256']:
                    raise ValueError('Numerical source preimage changed')
                backup = output / 'originals' / row['path']
                backup.parent.mkdir(parents=True, exist_ok=True)
                with backup.open('xb') as target:
                    target.write(destination.read_bytes())
                if sha(backup) != row['preimageSHA256']:
                    raise ValueError('Preserved numerical preimage changed')
        verify(before=True, require_snapshots=False)
        for row in rows:
            destination = WORKSPACE / row['path']
            temporary = destination.with_name(destination.name + '.numerical-new')
            with temporary.open('xb') as stream:
                stream.write(Path(row['sourcePath']).read_bytes())
                stream.flush()
                os.fsync(stream.fileno())
            if sha(temporary) != row['proposedSHA256']:
                raise ValueError('Prepared numerical source bytes changed')
            if row['preimageSHA256'] is None:
                os.link(temporary, destination)
                temporary.unlink()
            else:
                if destination.is_symlink() or sha(destination) != row['preimageSHA256']:
                    raise ValueError('Numerical preimage changed before replacement')
                os.replace(temporary, destination)
        receipt['after'] = verify(require_snapshots=False)
        for name, rows in zip(('source-snapshot-5.json', 'dependency-snapshot-5.json'), expected()):
            save(BASE / name, dict(members=rows))
        verify()
        receipt.update(status='passed', activationSHA256=sha(BASE / 'activation-1/activation.json'), snapshots={name: sha(BASE / name) for name in ('source-snapshot-5.json', 'dependency-snapshot-5.json')})
    finally:
        save(output / 'receipt.json', receipt)
    print(json.dumps(receipt, sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077)
    main()
