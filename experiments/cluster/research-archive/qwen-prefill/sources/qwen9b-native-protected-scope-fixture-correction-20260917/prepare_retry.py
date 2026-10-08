"""Root-only, one-file atomic replacement in the existing private build workspace."""
import json
import os
from pathlib import Path
from retry_inputs import BASE, WORKSPACE, sha, expected
from verify_retry import verify


def main():
    output = BASE / 'preparation-3'
    output.mkdir(mode=0o700)
    receipt = dict(status='started', workspace=str(WORKSPACE),
                   compilerExecuted=False, cacheCopied=False, remoteExecuted=False)
    try:
        for name in ('source-snapshot-3.json', 'dependency-snapshot-3.json'):
            if (BASE / name).exists() or (BASE / name).is_symlink():
                raise ValueError('Retry snapshots already exist')
        receipt['before'] = verify(before=True, require_snapshots=False)
        row, = json.loads((BASE / 'integration.json').read_bytes())['files']
        destination = WORKSPACE / row['path']
        if destination.is_symlink() or sha(destination) != row['beforeSHA256']:
            raise ValueError('Correction preimage changed')
        temporary = destination.with_name(destination.name + '.protected-scope-fixture-correction')
        raw = (BASE / 'proposed' / row['path']).read_bytes()
        with temporary.open('xb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        if sha(temporary) != row['afterSHA256'] or sha(destination) != row['beforeSHA256']:
            raise ValueError('Correction bytes changed before replacement')
        os.replace(temporary, destination)
        receipt['replacement'] = row
        receipt['after'] = verify(require_snapshots=False)
        for name, rows in zip(('source-snapshot-3.json', 'dependency-snapshot-3.json'), expected()):
            with (BASE / name).open('x') as stream:
                json.dump(dict(members=rows), stream, indent=2)
                stream.write('\n')
        receipt['snapshots'] = {name: sha(BASE / name) for name in
            ('source-snapshot-3.json', 'dependency-snapshot-3.json')}
        verify()
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt.update(status='failed', failure=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        with (output / 'receipt.json').open('x') as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write('\n')
    print(json.dumps(receipt, sort_keys=True))


if __name__ == '__main__':
    os.umask(0o077)
    main()
