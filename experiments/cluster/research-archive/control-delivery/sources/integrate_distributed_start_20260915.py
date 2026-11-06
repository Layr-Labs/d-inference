#!/usr/bin/env python3
"""Promote the reviewed installed-session, HTTP host and CLI sources together."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import time

RESEARCH = Path('/Users/developer/DarkbloomDev/cluster-research')
REPO = Path('/Users/developer/DarkbloomDev/d-inference')
OUT = RESEARCH / 'distributed-start-main-integration-20260915'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_manifest(folder, expected=None):
    path = folder / 'manifest.json'
    if expected:
        assert digest(path) == expected, path
    value = json.loads(path.read_text())
    members = value.get('members', value.get('files'))
    assert isinstance(members, list) and members, path
    for item in members:
        target = folder / item['path']
        assert digest(target) == item['sha256'], target
        if 'bytes' in item:
            assert target.stat().st_size == item['bytes'], target
    return {'path': str(path), 'sha256': digest(path), 'members': len(members)}


def main():
    assert not OUT.exists(), OUT
    installed = RESEARCH / 'distributed-installed-owner-draft'
    host = RESEARCH / 'distributed-local-server-draft-v2-20260915'
    cli = RESEARCH / 'distributed-start-draft-20260915'
    manifests = [verify_manifest(installed,
        '391122640456c33e9a7f0a426cdb62f4bf4b7345179c3b068903c1b3a6a55cb6'), verify_manifest(host,
        '2366713f577e42afeed042754522c747178938c6bede1c44b37de65bbb612c41')]
    review_path = RESEARCH / 'distributed-start-review-20260915/final-review.json'
    assert digest(review_path) == '3f02ba844b95061d0a4ab0fa6f2dd2218a438523535cada94ed168f9662210c0'
    review = json.loads(review_path.read_text())
    for path, pin in review['sources'].items():
        assert digest(Path(path)) == pin, path

    entries = []
    for item in json.loads((installed / 'integration.json').read_text())['files']:
        relative = Path(item['path'])
        entries.append((installed / 'proposed' / relative, REPO / relative,
            item['sha256'], item['sha256'] if item['alreadyPromotedIdentically'] else item['baseSHA256']))
    for item in json.loads((host / 'integration.json').read_text())['files']:
        entries.append((Path(item['source']), Path(item['destination']), item['sha256'], None))
    start_base = json.loads((cli / 'start-base.json').read_text())
    for source in sorted((cli / 'proposed').rglob('*.swift')):
        relative = source.relative_to(cli / 'proposed')
        baseline = start_base['originalSHA256'] if str(relative) == start_base['path'] else None
        entries.append((source, REPO / relative, digest(source), baseline))
    assert len({str(item[1]) for item in entries}) == len(entries)
    for source, target, pin, baseline in entries:
        assert source.is_file() and digest(source) == pin, source
        assert target.is_relative_to(REPO), target
        assert (digest(target) if target.exists() else None) == baseline, target

    OUT.mkdir()
    cli_parse = ['swiftc', '-frontend', '-parse'] + [str(path) for path in sorted((cli / 'proposed').rglob('*.swift'))]
    begun = time.monotonic()
    check = subprocess.run(cli_parse, capture_output=True)
    (OUT / 'cli-parse.stdout').write_bytes(check.stdout)
    (OUT / 'cli-parse.stderr').write_bytes(check.stderr)
    (OUT / 'cli-parse.json').write_text(json.dumps({'command': cli_parse, 'exitCode': check.returncode,
        'elapsedSeconds': time.monotonic() - begun}, indent=2) + '\n')
    assert check.returncode == 0
    promoted = []
    for source, target, pin, baseline in entries:
        relative = target.relative_to(REPO)
        if target.exists():
            backup = OUT / 'originals' / relative
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, backup)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        assert digest(target) == pin
        promoted.append({'path': str(relative), 'sha256': pin, 'originalSHA256': baseline})
    receipt = {'manifests': manifests, 'reviewSHA256': digest(review_path), 'files': promoted,
        'fullProviderBuildPending': True, 'nativeOrRemoteExecution': False}
    (OUT / 'promotion.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'promotedFiles': len(promoted), 'receipt': str(OUT / 'promotion.json')}))


if __name__ == '__main__':
    main()
