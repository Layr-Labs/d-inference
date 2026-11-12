"""Bounded archived-file identities and exact source-bound warning admission."""
from pathlib import Path
import re
from long_reference_provenance_common import files, raw, read, require, sha
from long_rank_provenance_records import LOOPBACK_STDERR


def warning_source(run, receipt):
    base = run / 'source/experiments/cluster/inference/Sources/ClusterInference'
    collective, options = base / 'Collective.swift', base / 'Options.swift'
    literal = 'log("' + LOOPBACK_STDERR.decode().rstrip('\n') + '")'
    text, logger = raw(collective, 1024**2).decode(), raw(options, 1024**2).decode()
    require(text.count(literal) == 1 and 'if transport == .loopbackTest {\n            ' + literal in text,
            'Archived loopback warning source differs')
    require('func log(_ message: String) {\n    FileHandle.standardError.write(Data((message + "\\n").utf8))\n}' in logger,
            'Archived warning encoding differs')
    expected = dict(expected_utf8=LOOPBACK_STDERR.decode(), exact_one_line_required=True,
                    source_sha256={'Collective.swift': sha(collective), 'Options.swift': sha(options)})
    require(receipt['stderr_contract'] == expected and receipt['stderr_contract']['exact_one_line_required'] is True,
            'Saved exact stderr/source contract differs')
    return expected


def provenance(run, receipt, pins, review_path, review_sha):
    require(sha(review_path) == review_sha, 'Frozen launcher review pin differs')
    review = read(review_path)
    require(review['kind'] == 'remote_registered9b_long_rank_launcher_source_freeze'
            and type(review['schema_version']) is int and review['schema_version'] == 1
            and review['native_execution_performed'] is False and review['candidate_output_accessed'] is False,
            'Wrong prospective launcher source review')
    proof = review['prospective_cpu_tests']
    require(proof['passed'] is True and type(proof['count']) is int and 1 <= proof['count'] <= 256
            and proof['python39_syntax_all_files_passed'] is True
            and proof['real_process_socket_entry_points_blocked'] is True, 'Prospective CPU proof differs')
    for entry in review['files']:
        path = Path(entry['path'])
        require(not path.is_absolute() and path.name == entry['path'], 'Launcher review requires flat relative files')
    tested = files(review_path.parent, review['files'])
    require(sha(run / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest differs')
    source = read(run / 'source-manifest.json'); sources = files(run / 'source', source['files'])
    require(type(receipt['source_file_count']) is int and 1 <= len(sources) == receipt['source_file_count'] <= 2048,
            'Archived source count differs')
    dependencies = source['dependencies']
    require(dependencies['tracked_dependency_changes'] == ''
            and re.fullmatch('[0-9a-f]{40}', dependencies['repository_head']), 'Dependency declaration differs')
    for line in dependencies['submodules'].splitlines():
        require(re.match(r'^\s*[0-9a-f]{40}\s+\S+', line), 'Submodule declaration malformed')
    for name, pin in review['repository_dependencies'].items():
        require(sources.get(name) == pin, 'Reviewed runtime/CLI source differs from archive')
    require(sha(run / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest differs')
    bundle = files(run / 'bundle', read(run / 'bundle/bundle.json')['files'])
    require(bundle['cluster-inference'] == pins.native, 'Explicit native binary pin differs')
    for name in ('rank_worker.py', 'artifacts.py'):
        require(bundle[name] == sources['experiments/cluster/runtime/' + name], 'Bundled runtime differs from archive')
    launcher = files(run / 'launcher', receipt['launcher_files'])
    require(launcher == {name: pin for name, pin in tested.items() if name.endswith('.py')},
            'Launcher archive differs from frozen reviewed source')
    require(sha(run / 'controls/control-manifest.json') == receipt['control_manifest_sha256'], 'Control manifest differs')
    controls = files(run / 'controls', read(run / 'controls/control-manifest.json')['files'])
    require(set(controls) == {'long_rank_control.py', 'prefill_compute_memory.py', 'artifacts.py', 'control-config.json'},
            'Control inventory differs')
    for name in ('long_rank_control.py', 'prefill_compute_memory.py'):
        require(controls[name] == tested[name], 'Staged control helper differs')
    require(controls['artifacts.py'] == bundle['artifacts.py'], 'Control artifact verifier differs')
    warning = warning_source(run, receipt)
    caps = {'rank.json': 256 * 1024, 'prompt.json': 65536, 'hosts.json': 1024,
            'stdout.jsonl': 8 * 1024**2, 'stderr.log': len(LOOPBACK_STDERR)}
    expected_files = {'rank-' + str(rank) + '/' + name for rank in range(2) for name in caps}
    entries = receipt['rank_files']
    require(len(entries) == 10 and {entry['path'] for entry in entries} == expected_files, 'Rank output/raw-input inventory differs')
    # Check small per-kind bounds before hashing any candidate output file.
    for entry in entries:
        path = Path(entry['path']); maximum = caps[path.name]
        require(type(entry['rank']) is int and path.parts[0] == 'rank-' + str(entry['rank'])
                and type(entry['maximum_bytes']) is int and entry['maximum_bytes'] == maximum
                and type(entry['size_bytes']) is int and 0 <= entry['size_bytes'] <= maximum
                and entry['hash_omitted_because_oversized'] is False
                and (run / path).stat().st_size <= maximum, 'Rank file exceeds its exact bound')
    ranks = files(run, entries)
    for rank in range(2):
        require(raw(run / ('rank-' + str(rank)) / 'stderr.log', len(LOOPBACK_STDERR)) == LOOPBACK_STDERR,
                'Rank stderr is not exactly the admitted warning line')
    inputs = files(run, receipt['inputs']['files'])
    require(set(inputs) == {'inputs/prompt.json', 'inputs/prompt-origin.json'}, 'Unexpected origin/raw-input archive')
    metadata = files(run, receipt['retrieved_remote_metadata'])
    names = {'before-config.json', 'before-manifest.json', 'after-config.json', 'after-manifest.json'}
    names |= {'rank-' + str(rank) + '-' + name for rank in range(2) for name in ('rank.json', 'prompt.json', 'hosts.json')}
    require(set(metadata) == {'remote-metadata/' + name for name in names}, 'Retrieved remote metadata inventory differs')
    return dict(source=sources, bundle=bundle, launcher=launcher, controls=controls, rankFiles=ranks,
                inputs=inputs, metadata=metadata, dependencies=dependencies, exactStderrContract=warning), bundle
