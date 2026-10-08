"""Narrow archive pins and the exact stderr source; no model/full-source audit."""
import re
from sidecar_files import bounded_bytes, file_record, parse, pin, require, sha

OWNER_RUNTIME = {
    'launch_remote_long_ranks.py': 'f12eb7cc2034e11b9dc1e92c13205c9e041ec92dd2f6a389a2eb15af985f71bf',
    'long_rank_configuration.py': 'b9d9cd763ca42875a134e41b1ad9ffebf0c92df553d6e3b467e317f78b93a03c',
    'long_rank_paths.py': 'ca1b6cd8dc9ecd34c3ca41f5ee6f9aeb26b7efd38b2e6630a4da69d994cc36fe',
}

WARNING = b'Using loopback-test transport for correctness only; timings are not cluster-performance evidence\n'


def archives(run, receipt):
    retained = {}
    for name, field in [('source-manifest.json', 'source_manifest_sha256'),
                        ('bundle/bundle.json', 'bundle_manifest_sha256')]:
        raw = bounded_bytes(run / name, 4 * 1024 * 1024)
        require(sha(raw) == pin(receipt[field]), 'Archive manifest pin differs: ' + name)
        retained[name] = file_record(name, raw)
    launcher = receipt['launcher_files']
    require(type(launcher) is list and 1 <= len(launcher) <= 64, 'Launcher archive count')
    names, total = set(), 0
    for entry in launcher:
        name = entry['path']
        require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_]+\.py', name) and name not in names,
                'Unsafe or repeated launcher archive path')
        names.add(name)
        raw = bounded_bytes(run / 'launcher' / name, 1024 * 1024)
        total += len(raw)
        require(total <= 8 * 1024 * 1024 and type(entry['size_bytes']) is int
                and len(raw) == entry['size_bytes'] and sha(raw) == pin(entry['sha256']), 'Launcher archive differs')
        if name in OWNER_RUNTIME:
            require(sha(raw) == OWNER_RUNTIME[name], 'Frozen rank-owner runtime source differs')
    require(set(OWNER_RUNTIME) <= names, 'Rank-owner launcher source missing')
    warning = receipt['stderr_contract']
    require(warning['expected_utf8'] == WARNING.decode() and warning['exact_one_line_required'] is True,
            'Wrong stderr contract')
    texts = {}
    for name in ('Collective.swift', 'Options.swift'):
        path = 'source/experiments/cluster/inference/Sources/ClusterInference/' + name
        raw = bounded_bytes(run / path, 256 * 1024)
        require(sha(raw) == pin(warning['source_sha256'][name]), 'Archived warning source differs')
        texts[name] = raw.decode('utf-8')
        retained[path] = file_record(path, raw)
    literal = 'log("' + WARNING.decode().rstrip('\n') + '")'
    require(texts['Collective.swift'].count(literal) == 1
            and 'if transport == .loopbackTest {\n            ' + literal in texts['Collective.swift']
            and 'func log(_ message: String) {\n    FileHandle.standardError.write(Data((message + "\\n").utf8))\n}'
            in texts['Options.swift'], 'Archived warning emission changed')
    return retained


def rank_files(run, receipt):
    limits = {'rank.json': 256 * 1024, 'prompt.json': 64 * 1024, 'hosts.json': 1024,
              'stdout.jsonl': 8 * 1024 * 1024, 'stderr.log': 64 * 1024}
    expected = {'rank-' + str(rank) + '/' + name: (rank, cap)
                for rank in (0, 1) for name, cap in limits.items()}
    require(type(receipt['rank_files']) is list and len(receipt['rank_files']) == 10,
            'Ten pinned rank files required')
    raw_files, retained = {}, []
    for entry in receipt['rank_files']:
        name = entry['path']
        require(name in expected and name not in raw_files, 'Unknown/repeated rank archive path')
        rank, maximum = expected[name]
        require(type(entry['rank']) is int and entry['rank'] == rank
                and entry.get('hash_omitted_because_oversized') is False, 'Rank archive identity or size invalid')
        raw = bounded_bytes(run / name, maximum)
        require(type(entry['size_bytes']) is int and len(raw) == entry['size_bytes']
                and sha(raw) == pin(entry['sha256']), 'Pinned rank file differs: ' + name)
        raw_files[name] = raw
        retained.append(dict(file_record(name, raw), rank=rank))
    return raw_files, retained
