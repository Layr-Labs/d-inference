"""Scheduled preparation only; preserve old bytes before the guarded overlay."""
from pathlib import Path
import json
import os
import shutil

from inputs import BASE, INPUTS, WORK, SCRATCH, authorities, expected_sources, inventory, original_dependencies, original_sources, sha, verify_final, write_json


def main():
    output = BASE / 'preparation-1'
    if output.exists():
        raise ValueError('Preparation output already exists; retain it')
    authorities()
    if inventory(WORK) != original_sources() or inventory(SCRATCH / 'checkouts') != original_dependencies():
        raise ValueError('Exact 3075/8755 predecessor is no longer available')
    overlay = json.loads(Path(INPUTS['acceptedIntegration']['path']).read_bytes())['files']
    for value in overlay:
        target = WORK / value['path']
        if value['beforeSHA256'] is None:
            if target.exists() or target.is_symlink():
                raise ValueError('New overlay already exists')
        elif target.is_symlink() or sha(target) != value['beforeSHA256']:
            raise ValueError('Overlay preimage changed')
    for name in INPUTS['referenceFiles']:
        if (WORK / name).exists() or (WORK / name).is_symlink():
            raise ValueError('Reference destination already exists')
    release = SCRATCH / 'arm64-apple-macosx/release'
    old = release / 'TargetVerificationSessionCheck'
    if sha(old) != INPUTS['oldNativeSHA256']:
        raise ValueError('Prior qualified tiny Session binary changed')
    output.mkdir(mode=0o700)
    receipt = dict(status='started', applied=[], sourceBeforeSHA256=INPUTS['baseSource']['sha256'],
                   dependenciesSHA256=INPUTS['baseDependencies']['sha256'], preservedProducts=[],
                   compilerExecuted=False, modelExecuted=False, remoteExecuted=False)

    def save():
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')

    try:
        write_json(output / 'source-before.json', dict(members=original_sources()))
        write_json(output / 'dependencies-before.json', dict(members=original_dependencies()))
        for name in ['TargetVerificationSessionCheck', 'darkbloom-cluster-worker', 'cluster-inference']:
            source = release / name
            if source.exists():
                if source.is_symlink():
                    raise ValueError('Prior product must be a regular file')
                target = output / 'prior-products' / name; target.parent.mkdir(exist_ok=True, mode=0o700)
                shutil.copyfile(source, target)
                if sha(source) != sha(target):
                    raise ValueError('Prior product backup differs')
                receipt['preservedProducts'].append(dict(name=name, sha256=sha(target), bytes=target.stat().st_size))
        copies = [(Path(x['sourcePath']), WORK / x['path'], x['beforeSHA256']) for x in overlay]
        for name in INPUTS['referenceFiles']:
            source = Path(INPUTS['referenceBase']) / name
            if name == INPUTS['referencePackage']['path']:
                source = BASE / 'reference-Package.swift'
            elif name == INPUTS['referenceResolved']['path']:
                source = BASE / 'reference-Package.resolved'
            copies.append((source, WORK / name, None))
        # No destination writes occur until all source, absence and backup guards pass.
        for source, target, before in copies:
            if before is not None:
                saved = output / 'originals' / target.relative_to(WORK)
                saved.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                shutil.copyfile(target, saved)
                if sha(saved) != before or sha(target) != before:
                    raise ValueError('Preimage changed before replacement')
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(target.name + '.mtp-preparation-new')
            with temporary.open('xb') as out:
                out.write(source.read_bytes()); out.flush(); os.fsync(out.fileno())
            os.chmod(temporary, 0o644)
            if before is None:
                os.link(temporary, target); temporary.unlink()
            else:
                os.replace(temporary, target)
            receipt['applied'].append(str(target.relative_to(WORK))); save()
        receipt['final'] = verify_final()
        write_json(output / 'source-after.json', dict(members=expected_sources()))
        receipt.update(status='passed', sourceAfterSHA256=sha(output / 'source-after.json'))
    except BaseException as error:
        receipt.update(status='failed', failure=type(error).__name__ + ': ' + str(error))
        raise
    finally:
        save()


if __name__ == '__main__':
    main()
