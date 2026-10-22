"""Root-only copy/verify into one fresh owner tree; no native or owner launch."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import tarfile
import time
from assemble import BASE, pin
from copy_owned import invoke_controller
from parent_settings import SSH


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--rank', type=int, choices=(0, 1), required=True)
    args = parser.parse_args()
    for name, expected in json.loads((BASE / 'manifest.json').read_bytes())['files'].items():
        value = pin(BASE / name)
        if value['bytes'] != expected['bytes'] or value['sha256'] != expected['sha256']:
            raise RuntimeError('Frozen preparation changed: ' + name)
    plan_raw = (BASE / ('deployment-rank' + str(args.rank) + '.json')).read_bytes()
    plan = json.loads(plan_raw)
    assert plan_raw.endswith(b'\n') and plan_raw.count(b'\n') == 1 and len(plan['files']) == 14
    output = BASE / ('copy-rank' + str(args.rank) + '-1')
    output.mkdir(mode=0o700)
    for item in plan['files'].values():
        observed = pin(Path(item['source']))
        assert observed['bytes'] == item['bytes'] and observed['sha256'] == item['sha256']
    payload = output / 'deployment.payload'
    with payload.open('xb') as stream:
        stream.write(plan_raw)
        with tarfile.open(fileobj=stream, mode='w|', format=tarfile.USTAR_FORMAT) as archive:
            for name, item in sorted(plan['files'].items()):
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = item['bytes'], item['mode'], 0
                with Path(item['source']).open('rb') as source:
                    archive.addfile(info, source)
    command = SSH + ['-S', 'none', ['darkbloom-24', 'darkbloom-48'][args.rank],
        shlex.join(['/usr/bin/python3', '-B', '-c', (BASE / 'install_new_tree.py').read_text()])]
    receipt = dict(rank=args.rank, argv=command, deploymentSHA256=hashlib.sha256(plan_raw).hexdigest(),
        nativeOrOwnerLaunched=False, existingTreeMutationRequested=False)
    started = time.monotonic()
    try:
        with payload.open('rb') as source, (output / 'stdout').open('xb') as stdout, (output / 'stderr').open('xb') as stderr:
            invoke_controller(command, stdout, stderr, receipt, timeout=180, stdin=source)
        assert receipt['exitCode'] == 0 and receipt['reaped'] and receipt['groupAbsent']
        assert (output / 'stderr').stat().st_size == 0 and (output / 'stdout').stat().st_size <= 128 * 1024
        value = json.loads((output / 'stdout').read_bytes())
        assert value['manifestSHA256'] == receipt['deploymentSHA256']
        assert value['verified'] == {name: {key: row[key] for key in ['bytes', 'sha256']} for name, row in plan['files'].items()}
        assert value['modelOrOwnerLaunched'] is False and value['existingInputsModified'] is False
        receipt['passed'] = True
    finally:
        receipt.update(elapsedSeconds=time.monotonic() - started,
            stdout=pin(output / 'stdout'), stderr=pin(output / 'stderr'))
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(dict(rank=args.rank, passed=True, verifiedFiles=14, output=str(output))))


if __name__ == '__main__':
    main()
