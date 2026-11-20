"""Preserve the prior binary and replace one producer plus add its typed record file."""
import json
import os
import shutil
from pathlib import Path
from retry_inputs import BASE, CORRECTION, WORKSPACE, SCRATCH, sha, expected
from verify_retry import verify

def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')

def main():
    output = BASE / 'preparation-4'
    output.mkdir(mode=0o700)
    receipt = dict(status='failed', compilerExecuted=False, cacheCopied=False, remoteExecuted=False)
    try:
        receipt['before'] = verify(before=True, require_snapshots=False)
        native = SCRATCH / 'arm64-apple-macosx/release/darkbloom-cluster-worker'
        digest = 'a0ecbb951d1bc3116758d8ef2c34eb4e2ed179dedcbcd54985869d467af14bac'
        if native.is_symlink() or sha(native) != digest:
            raise ValueError('Actual native3 binary differs')
        # A single 45 MB binary is preserved; no build cache is cloned.
        with native.open('rb') as source, (output / 'darkbloom-cluster-worker.native3').open('xb') as target:
            shutil.copyfileobj(source, target, length=1024 * 1024)
        if sha(output / 'darkbloom-cluster-worker.native3') != digest:
            raise ValueError('Preserved binary differs')
        rows = json.loads((CORRECTION / 'integration.json').read_bytes())['files']
        for row in rows:
            destination = WORKSPACE / row['path']
            if row['preimageSHA256'] is None:
                if destination.exists() or destination.is_symlink():
                    raise ValueError('New typed record destination already exists')
            else:
                if destination.is_symlink() or sha(destination) != row['preimageSHA256']:
                    raise ValueError('Producer preimage changed')
                backup = output / 'originals' / row['path']
                backup.parent.mkdir(parents=True)
                with backup.open('xb') as target:
                    target.write(destination.read_bytes())
                if sha(backup) != row['preimageSHA256']:
                    raise ValueError('Preserved producer preimage changed')
        verify(before=True, require_snapshots=False)
        for row in rows:
            destination = WORKSPACE / row['path']
            temporary = destination.with_name(destination.name + '.canonical-new')
            with temporary.open('xb') as stream:
                stream.write(Path(row['sourcePath']).read_bytes())
                stream.flush()
                os.fsync(stream.fileno())
            if sha(temporary) != row['proposedSHA256']:
                raise ValueError('Prepared producer bytes changed')
            if row['preimageSHA256'] is None:
                os.link(temporary, destination)
                temporary.unlink()
            else:
                if destination.is_symlink() or sha(destination) != row['preimageSHA256']:
                    raise ValueError('Producer changed before replacement')
                os.replace(temporary, destination)
        receipt['after'] = verify(require_snapshots=False)
        for name, rows in zip(('source-snapshot-4.json', 'dependency-snapshot-4.json'), expected()):
            save(BASE / name, dict(members=rows))
        verify()
        receipt.update(status='passed', snapshots={name: sha(BASE / name) for name in ('source-snapshot-4.json', 'dependency-snapshot-4.json')})
    finally:
        save(output / 'receipt.json', receipt)
    print(json.dumps(receipt, sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077)
    main()
