"""Assemble the existing six-role packet against the frozen cut16 8K numerical gate."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
COMPARATOR = ROOT / 'qwen27b-cut16-numerical-audit-20260915'
COMPARATOR_SHA = 'f3757094f14cc479e761b83b2a988551250bd61a9dba1797e91c3e564f29aebe'
PARENT = ROOT / 'qwen27b-8k-serial-owner-qualification-20260915'
PARENT_SHA = 'c479d8277855431bf3acfd0a9310fcd23ada9ee6cf84c741323a24a625f9fcd2'
AGREEMENT_SHA = '5964b5f1e865fe2d12f3146ff600b0675db24d427ff979f8bde72c24b309172e'
SOURCE_ROLES = {
    'prompt': ('inputs/prompt.ids.json', 'ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997', 256*1024),
    'registered_request': ('inputs/request.json', 'd6813ee4697450a618c8027336e6925f94afe230e3e1a031135c3435fd03e57b', 64*1024),
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
    from audit_reference import check_reference
    check_reference(read('reference_stdout', reference, reference_sha, 32*1024**2), context)
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
    parser.add_argument('--reference', required=True)
    parser.add_argument('--reference-sha256', required=True)
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
    packet = assemble(args.reference, args.reference_sha256, ranks)
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
