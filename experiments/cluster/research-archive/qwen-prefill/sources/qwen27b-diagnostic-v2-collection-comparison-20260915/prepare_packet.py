"""Assemble the existing six-role packet; numerical policy stays in frozen d072."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
COMPARATOR = ROOT / 'registered-generation-numerical-audit-draft-20260915'
COMPARATOR_SHA = 'd072d1e04b673850ad94815335ccb3d5fb1db3a7d00d60abecc2fb14fca972f2'
PARENT = ROOT / 'qwen27b-owner-native-diagnostic-rerun-v2-20260915'
PARENT_SHA = '68bb635a1b28eefd54df3b49a72da12aabc0302fa6df085651e4f712c4f10e75'
AGREEMENT_SHA = '6a008e5e29f3bd4c2a79398700f0476bcd970111c95a88133a5becbb22f9973d'
REFERENCE = ROOT / 'qwen27b-full-generation-reference-physical-20260915/run-4/returned/native/worker-0.stdout'
REFERENCE_SHA = '65c39fab8ae0fd2dfe8b1a3839d299ab297a103affca7c6e5f45d6d72c53a36e'
SOURCE_ROLES = {
    'prompt': ('inputs/prompt.ids.json', '6d4c8898c3d6f01ddd8c3e712cde5005c647db64937977dd907935146442e81e', 256*1024),
    'registered_request': ('inputs/request.json', 'd81435faed6ae00db8251530e96da2d276443a62ffa6a971925075b8ec447401', 64*1024),
    'registered_plan': ('provenance/recording-metadata.json', 'd1828272d22d62bd4573cf0da04aa7797e2b18aa59286bd34916cf77c7b8b9d4', 64*1024),
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
    for item in value['files']:
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
