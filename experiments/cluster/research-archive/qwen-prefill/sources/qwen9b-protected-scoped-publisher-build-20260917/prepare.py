"""Replace one exact source preimage; no cache clone or compiler."""
import json
import os
from pathlib import Path
from retry_inputs import BASE, WORKSPACE, SCRATCH, sha, expected
from verify_retry import verify

def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')

def main():
    output = BASE / 'preparation-7'; output.mkdir(mode=0o700)
    receipt = dict(status='failed', compilerExecuted=False, cacheCopied=False, remoteExecuted=False)
    try:
        receipt['before'] = verify(before=True, require_snapshots=False)
        binary = SCRATCH / 'arm64-apple-macosx/release/darkbloom-cluster-worker'
        if binary.is_symlink() or sha(binary) != 'dd277746f02ef87e00a517b63932a111ea986b1a4c361718ba8cf05012d9dd70':
            raise ValueError('Cached canonical native changed after failed compile')
        row = json.loads((BASE / 'integration.json').read_bytes())['files'][0]
        destination = WORKSPACE / row['path']; source = Path(row['sourcePath'])
        if destination.is_symlink() or sha(destination) != row['preimageSHA256'] or source.is_symlink() or sha(source) != row['proposedSHA256']:
            raise ValueError('Thunk source binding changed')
        with (output / 'original.swift').open('xb') as stream: stream.write(destination.read_bytes())
        verify(before=True, require_snapshots=False)
        temporary = destination.with_name(destination.name + '.scoped-publisher-new')
        with temporary.open('xb') as stream:
            stream.write(source.read_bytes()); stream.flush(); os.fsync(stream.fileno())
        if sha(temporary) != row['proposedSHA256'] or sha(destination) != row['preimageSHA256']:
            raise ValueError('Source changed before replacement')
        os.replace(temporary, destination)
        receipt['after'] = verify(require_snapshots=False)
        for name, rows in zip(('source-snapshot-7.json','dependency-snapshot-7.json'), expected()):
            save(BASE / name, dict(members=rows))
        verify(); receipt['status'] = 'passed'
    finally: save(output / 'receipt.json', receipt)
    print(json.dumps(receipt, sort_keys=True))

if __name__ == '__main__':
    os.umask(0o077); main()
