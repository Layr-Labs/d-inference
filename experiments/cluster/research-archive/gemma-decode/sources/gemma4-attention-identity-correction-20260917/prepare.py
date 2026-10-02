"""Run only after a root materialization grant. Preserves the prior binary."""
import json, shutil
from common import BASE, WORKSPACE, BINARY, authorities, expected, sha, verify

def main():
    value = authorities()
    out = BASE / 'preparation'; out.mkdir(mode=0o700)
    receipt = dict(status='started', compilerExecuted=False, remoteExecuted=False)
    try:
        receipt['before'] = verify(False)
        if BINARY.is_symlink() or sha(BINARY) != value['originalNativeSHA256']:
            raise ValueError('Original qualified binary changed')
        retained = out / 'GemmaShortCorrectnessCheck.before'
        shutil.copy2(BINARY, retained)
        if sha(retained) != value['originalNativeSHA256']: raise ValueError('Old binary retention differs')
        receipt['retainedOriginalBinary'] = dict(path=str(retained), sha256=sha(retained))
        for row in value['overlays']:
            target = WORKSPACE / row['path']
            if row['beforeSHA256'] is None:
                if target.exists() or target.is_symlink(): raise ValueError('Unexpected added source')
            elif target.is_symlink() or sha(target) != row['beforeSHA256']:
                raise ValueError('Source preimage changed')
        # Every preimage was validated before any source mutation. Frozen
        # originals also remain in BASE/originals, outside the mutable workspace.
        for row in value['overlays']:
            target = WORKSPACE / row['path']
            target.write_bytes((BASE / row['source']).read_bytes())
        receipt['after'] = verify(True)
        with (out / 'source-snapshot.json').open('x') as handle:
            json.dump(dict(members=expected()), handle, indent=2); handle.write('\n')
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt['status'] = 'failed'; receipt['failure'] = type(error).__name__ + ': ' + str(error); raise
    finally:
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    print(json.dumps(receipt['after'], sort_keys=True))

if __name__ == '__main__': main()
