"""Assemble the existing six-role packet against the frozen cut16 numerical gate."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
COMPARATOR = ROOT / 'qwen27b-cut16-numerical-audit-20260915'
COMPARATOR_SHA = 'f3757094f14cc479e761b83b2a988551250bd61a9dba1797e91c3e564f29aebe'
PARENT = ROOT / 'qwen27b-cut16-owner-qualification-20260915'
PARENT_SHA = '4690e10bee7fcb9c9d5dfd76dd58c9b7344e1d9ee1479f24ea3976ef6d3c1641'
AGREEMENT_SHA = '42c310634e03957f611a2c827347f1faf3d6bcc06003296b6c398932b4b56b2e'
REFERENCE = ROOT / 'qwen27b-cut16-full-reference-20260915/physical-collect-1/returned/native/worker-0.stdout'
REFERENCE_SHA = '539f0ed31bf4b95590d26df3468b2d3863520bc742d2c62cd37bcb8ca94d6e26'
SOURCE_ROLES = {
    'prompt': ('inputs/prompt.ids.json', '6d4c8898c3d6f01ddd8c3e712cde5005c647db64937977dd907935146442e81e', 256*1024),
    'registered_request': ('inputs/request.json', '3b9ca1f74695c1e79a895954cbb26e14857e83c5504c09f26a2f25ac66d00a4f', 64*1024),
    'registered_plan': ('provenance/recording-metadata.json', '4c22d847bb83991a37d83a9c97be94eb8152f5341c8deaa4b3bf6e677eb6eeeb', 64*1024),
}


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return h.hexdigest()


def verify_package(directory, expected):
    manifest = directory / 'manifest.json'
    if manifest.is_symlink() or manifest.stat().st_size > 1024**2 or digest(manifest) != expected:
        raise ValueError('Frozen source manifest differs')
    value = json.loads(manifest.read_bytes())
    members = value['files']
    if type(members) is dict:
        members = [dict(path=name, bytes=item['bytes'], sha256=item['sha256'])
                   for name, item in members.items()]
    for item in members:
        path = directory / item['path']
        if path.is_symlink() or path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            raise ValueError('Frozen source member differs: ' + item['path'])


def bootstrap():
    verify_package(COMPARATOR, COMPARATOR_SHA)
    verify_package(PARENT, PARENT_SHA)
    sys.path.insert(0, str(COMPARATOR))


def assemble(reference, reference_sha, ranks):
    from audit_common import parse, exact, agreement, request_context, sha
    from audit_scope import pinned_scope
    from snapshot import snapshot
    saved = []
    identities = set()
    files = {}

    def read(role, path, expected, limit):
        path = Path(path).absolute()
        item = snapshot(path, limit)
        exact(item['sha256'], sha(expected), role + ' pin')
        if item['identity'][:2] in identities:
            raise ValueError('Distinct artifact files required')
        identities.add(item['identity'][:2])
        saved.append((path, limit, item))
        if role != 'expected_agreement':
            files[role] = {'path': str(path), 'sha256': item['sha256']}
        return item['raw']

    source = {role: read(role, PARENT / name, expected, limit)
              for role, (name, expected, limit) in SOURCE_ROLES.items()}
    expected = parse(read('expected_agreement', PARENT / 'expected-agreement.json', AGREEMENT_SHA, 64*1024))
    request = parse(source['registered_request'])
    context = request_context(source['prompt'], request['requestID'],
                              pinned_scope(request, parse(source['registered_plan'])))
    agreement(expected, context)
    read('reference_stdout', reference, reference_sha, 32*1024**2)
    if len(ranks) != 2:
        raise ValueError('Exactly two rank artifacts required')
    for rank, (path, expected_sha) in enumerate(ranks):
        read('rank' + str(rank) + '_evidence', path, expected_sha, 16*1024**2)
    for path, limit, before in saved:
        exact(snapshot(path, limit, keep=False), dict(before, raw=None), 'artifact recheck')
    return {'schema': 'private_registered_generation_comparison_packet_v1',
            'request_id': request['requestID'], 'expected_agreement': expected, 'files': files}


def collected_ranks(path, expected_sha):
    from audit_common import parse, exact, sha
    from snapshot import snapshot
    path = Path(path).absolute()
    item = snapshot(path, 64*1024)
    exact(item['sha256'], sha(expected_sha), 'collection receipt pin')
    value = parse(item['raw'])
    exact(value['schema'], 'qwen27b_sidecars_collected_v1', 'collection schema')
    exact(value['status'], 'collected', 'collection status')
    exact(value['parentManifestSHA256'], PARENT_SHA, 'collection parent')
    exact(value['comparatorManifestSHA256'], COMPARATOR_SHA, 'collection comparator')
    exact(value['readerSHA256'], digest(Path(__file__).with_name('read_sidecar_remote.py')), 'collection reader')
    if type(value['ranks']) is not list or len(value['ranks']) != 2:
        raise ValueError('Both collected ranks required')
    ranks = []
    for rank, record in enumerate(value['ranks']):
        exact(record['rank'], rank, 'ordered rank')
        exact(record['status'], 'collected', 'rank collected')
        exact(record['host'], ('darkbloom-24', 'darkbloom-48')[rank], 'ordered host')
        ranks.append((record['path'], sha(record['sha256'])))
    return ranks, (path, item)


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    for rank in (0, 1):
        parser.add_argument('--rank' + str(rank) + '-evidence')
        parser.add_argument('--rank' + str(rank) + '-sha256')
    parser.add_argument('--collection')
    parser.add_argument('--collection-sha256')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    bootstrap()
    manual = [args.rank0_evidence, args.rank0_sha256, args.rank1_evidence, args.rank1_sha256]
    collection = None
    if args.collection or args.collection_sha256:
        if not (args.collection and args.collection_sha256) or any(manual):
            parser.error('Choose a pinned collection or four explicit rank arguments')
        ranks, collection = collected_ranks(args.collection, args.collection_sha256)
    else:
        if not all(manual):
            parser.error('Choose a pinned collection or four explicit rank arguments')
        ranks = [(args.rank0_evidence, args.rank0_sha256), (args.rank1_evidence, args.rank1_sha256)]
    packet = assemble(REFERENCE, REFERENCE_SHA, ranks)
    if collection:
        from snapshot import snapshot
        from audit_common import exact
        path, before = collection
        exact(snapshot(path, 64*1024, keep=False), dict(before, raw=None), 'collection recheck')
    from audit_generation import write_result
    write_result(args.output, packet)
    print(json.dumps({'status': 'packet_prepared', 'packetSHA256': digest(Path(args.output)),
                      'comparisonExecuted': False, 'physicalCleanupVerified': False}, sort_keys=True))


if __name__ == '__main__':
    main()
