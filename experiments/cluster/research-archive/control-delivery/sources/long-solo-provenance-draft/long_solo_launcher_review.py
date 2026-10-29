"""Bind the solo delta to its pinned, unchanged upstream launcher helpers."""
from long_reference_provenance_common import files, read, require, sha, valid_hash

UNCHANGED_HELPERS = frozenset({
    'long_reference_artifacts.py', 'long_reference_inputs.py',
    'prefill_compute_archive.py', 'prefill_compute_memory.py',
    'remote_prefill_client.py', 'remote_prefill_control.py',
    'remote_prefill_paths.py', 'remote_prefill_supervision.py',
})


def launcher_review(path, expected_sha256):
    valid_hash(expected_sha256)
    require(sha(path) == expected_sha256, 'Frozen solo launcher review pin differs')
    review = read(path)
    checks = review['cpu_tests']
    require(review['kind'] == 'long_solo_launcher_source_review'
            and type(checks['exit_code']) is int and checks['exit_code'] == 0
            and type(checks['tests']) is int and checks['tests'] == 18
            and checks['real_processes_sockets_forbidden'] is True
            and checks['python39_syntax_passed'] is True
            and review['native_run'] is False, 'Prospective solo launcher proof differs')
    valid_hash(checks['log_sha256'])
    names = review['unchanged_upstream_files']
    require(type(names) is list and len(names) == len(UNCHANGED_HELPERS)
            and all(type(name) is str for name in names)
            and set(names) == UNCHANGED_HELPERS, 'Inherited helper declaration differs')
    tested = files(path.parent, review['files'])
    upstream_path = path.parent.parent / 'remote-long-reference-launcher-draft/source-review-20260914.json'
    upstream_pin = valid_hash(review['upstream_manifest_sha256'])
    require(sha(upstream_path) == upstream_pin, 'Frozen upstream launcher review pin differs')
    upstream = read(upstream_path)
    checks = upstream['prospective_cpu_tests']
    require(upstream['kind'] == 'remote_registered9b_long_reference_launcher_source_freeze'
            and checks['passed'] is True and type(checks['count']) is int and checks['count'] == 18
            and checks['real_process_socket_entry_points_blocked'] is True
            and checks['python39_syntax_all_files_passed'] is True
            and upstream['scope']['ssh_or_native_execution'] is False,
            'Prospective upstream launcher proof differs')
    valid_hash(checks['log_sha256'])
    inherited = files(upstream_path.parent, upstream['files'])
    for name in UNCHANGED_HELPERS:
        require(name in tested and tested[name] == inherited.get(name), 'Inherited launcher helper changed: ' + name)
    dependencies = upstream['repository_dependencies']
    require(type(dependencies) is dict and 1 <= len(dependencies) <= 2048, 'Invalid upstream dependency map')
    for pin in dependencies.values(): valid_hash(pin)
    require(sha(path) == expected_sha256 and sha(upstream_path) == upstream_pin, 'Review changed during audit')
    return tested, dependencies, upstream_pin
