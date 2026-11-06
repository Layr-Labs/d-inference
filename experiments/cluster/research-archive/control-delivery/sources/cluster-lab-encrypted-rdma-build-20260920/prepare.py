"""Scheduled source overlay only; retain native7 binary and Package.swift before edits."""
import json
import os
import shutil

from guards import BASE, INPUTS, PRODUCT, RELEASE, SOURCE, WORK, fresh, inventory_check, pin, save_receipt, sha


def main():
    output = BASE / 'preparation-1'
    if output.exists():
        raise ValueError('Retain existing preparation; no automatic retry')
    inventory_check(False)
    rows = json.loads((SOURCE / 'overlay.json').read_bytes())['files']
    for row in rows:
        target = WORK / row['destination']
        if row['preimageSHA256'] is None:
            if target.exists() or target.is_symlink():
                raise ValueError('New source destination already exists')
        elif target.is_symlink() or sha(target) != row['preimageSHA256']:
            raise ValueError('Package preimage changed')
    old = RELEASE / 'darkbloom-cluster-worker'
    if pin(old) != {key: INPUTS['priorBinary'][key] for key in ('bytes', 'sha256')}:
        raise ValueError('Prior native7 binary changed')
    if (RELEASE / PRODUCT).exists() or (RELEASE / PRODUCT).is_symlink():
        raise ValueError('Lab product already exists')
    fresh(output)
    receipt = dict(schema='lab_rdma_preparation_v1', status='started', applied=[], compilerExecuted=False,
                   gpuExecuted=False, sourceManifestSHA256=INPUTS['authorities']['nativeManifest']['sha256'])
    try:
        receipt['before'] = inventory_check(False, output)
        shutil.copyfile(old, output / 'native7-preserved')
        if pin(output / 'native7-preserved') != pin(old):
            raise ValueError('Preserved predecessor binary differs')
        receipt['preservedBinary'] = pin(output / 'native7-preserved')
        for row in rows:
            target = WORK / row['destination']
            if row['preimageSHA256'] is not None:
                saved = output / 'Package.original.swift'
                shutil.copyfile(target, saved)
                if sha(saved) != row['preimageSHA256'] or sha(target) != row['preimageSHA256']:
                    raise ValueError('Package changed before replacement')
        # Every original/absence and prior product is checked before the first write.
        for row in rows:
            target = WORK / row['destination']
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + '.lab-new')
            raw = (SOURCE / row['source']).read_bytes()
            with temporary.open('xb') as out:
                out.write(raw); out.flush(); os.fsync(out.fileno())
            os.chmod(temporary, 0o644)
            if pin(temporary) != dict(bytes=row['bytes'], sha256=row['sha256']):
                raise ValueError('Staged source differs')
            if row['preimageSHA256'] is None:
                os.link(temporary, target); temporary.unlink()
            else:
                if target.is_symlink() or sha(target) != row['preimageSHA256']:
                    raise ValueError('Package preimage changed at replacement')
                os.replace(temporary, target)
            receipt['applied'].append(row['destination'])
            save_receipt(output / 'receipt.json', receipt)
        receipt['after'] = inventory_check(True)
        receipt.update(status='passed', preservedPackageSHA256=sha(output / 'Package.original.swift'))
    except BaseException as error:
        receipt.update(status='failed', failure=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        save_receipt(output / 'receipt.json', receipt)
    print(json.dumps(dict(status=receipt['status'], receiptSHA256=sha(output / 'receipt.json'))))


if __name__ == '__main__':
    main()
