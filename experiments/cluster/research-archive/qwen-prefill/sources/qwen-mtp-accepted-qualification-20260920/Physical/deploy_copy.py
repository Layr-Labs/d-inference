"""Explicit root copy-only action, one rank, one fresh fixed namespace."""
import argparse
import json
from pathlib import Path
import shlex
import tarfile

from common import BASE, canonical, local_execute, sha, verify_bound, verify_sources, write_json


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--bound', required=True, type=Path)
    parser.add_argument('--binding-sha256', required=True)
    parser.add_argument('--rank', required=True, type=int, choices=[0, 1])
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(); verify_sources(); verify_bound(args.bound, args.binding_sha256)
    if not args.output.is_absolute() or args.output != args.output.resolve() or args.output.exists():
        raise ValueError('Fresh canonical copy output required')
    setup = json.loads((args.bound / 'off/configuration/controller.json').read_bytes())
    peer = setup['peers'][args.rank]
    plan_path = args.bound / ('deployment-rank' + str(args.rank) + '.json')
    plan = json.loads(plan_path.read_bytes())
    for row in plan['files'].values():
        path = Path(row['source'])
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Actual transfer source changed')
    args.output.mkdir(mode=0o700)
    archive_path = args.output / 'copy.input'
    with archive_path.open('xb') as stream:
        stream.write(canonical(plan))
        with tarfile.open(fileobj=stream, mode='w|', format=tarfile.USTAR_FORMAT) as archive:
            for name, row in sorted(plan['files'].items()):
                info = tarfile.TarInfo(name); info.size=row['bytes']; info.mode=row['mode']; info.mtime=0
                with Path(row['source']).open('rb') as source:
                    archive.addfile(info, source)
    installer = (args.bound / 'install_new_tree.py').read_text()
    command = ['/usr/bin/ssh', '-T', '-S', 'none', '-p', str(peer['port']), '-i', peer['identityFile'],
        '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
        '-o', 'UserKnownHostsFile=' + peer['knownHostsFile'], '-o', 'ConnectTimeout=5',
        peer['user'] + '@' + peer['host'], shlex.join(['/usr/bin/python3', '-B', '-c', installer])]
    execute = local_execute(args.bound)
    with archive_path.open('rb') as source:
        code = execute(command, args.output, 'copy', 180, stdin=source, cap=1024**2)
    if code != 0 or (args.output / 'copy.stderr').stat().st_size:
        raise ValueError('Copy failed; retain partial namespace and owned receipt')
    actual = json.loads((args.output / 'copy.stdout').read_bytes())
    expected = {name:{key:row[key] for key in ['bytes','sha256']} for name,row in plan['files'].items()}
    if actual['verified'] != expected or actual['modelOrOwnerLaunched'] or actual['existingInputsModified']:
        raise ValueError('Actual remote full-copy verification differs')
    for row in plan['files'].values():
        if sha(Path(row['source'])) != row['sha256']:
            raise ValueError('Copy source changed')
    verify_bound(args.bound, args.binding_sha256); verify_sources()
    write_json(args.output / 'copy-result.json', dict(status='passed', rank=args.rank,
        bindingSHA256=args.binding_sha256, deploymentSHA256=sha(plan_path), verifiedFiles=len(expected),
        journal=actual['canonicalJournalObserved'], ownedExecutionSHA256=sha(args.output / 'copy.execution.json'),
        remoteVerificationSHA256=sha(args.output / 'copy.stdout'), modelOrOwnerLaunched=False))


if __name__ == '__main__':
    main()
