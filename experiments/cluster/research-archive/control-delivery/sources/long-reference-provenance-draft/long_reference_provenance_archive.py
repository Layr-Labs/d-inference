"""Source/launcher/bundle/control file inventories; never imports their code."""
import re
from long_reference_provenance_common import files, read, require, sha


def provenance(run, receipt, pins, review_path, review_sha256):
    require(sha(review_path) == review_sha256, 'Frozen launcher review pin differs')
    review = read(review_path)
    require(review['kind'] == 'remote_registered9b_long_reference_launcher_source_freeze'
            and review['prospective_cpu_tests']['passed'] is True
            and review['prospective_cpu_tests']['count'] == 18
            and review['prospective_cpu_tests']['real_process_socket_entry_points_blocked'] is True
            and review['scope']['ssh_or_native_execution'] is False, 'Prospective launcher proof differs')
    tested = files(review_path.parent, review['files'])
    require(sha(run / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest differs')
    source = read(run / 'source-manifest.json')
    sources = files(run / 'source', source['files'])
    require(type(receipt['source_file_count']) is int and 1 <= len(sources) == receipt['source_file_count'] <= 2048,
            'Source count differs')
    dependencies = source['dependencies']
    require(dependencies['tracked_dependency_changes'] == ''
            and re.fullmatch('[0-9a-f]{40}', dependencies['repository_head']), 'Dependency declaration differs')
    for line in dependencies['submodules'].splitlines():
        require(re.match(r'^\s*[0-9a-f]{40}\s+\S+', line), 'Submodule identity malformed')
    for name, pin in review['repository_dependencies'].items():
        require(sources.get(name) == pin, 'Inspected runtime/CLI source differs from archive')
    require(sha(run / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest differs')
    bundle = files(run / 'bundle', read(run / 'bundle/bundle.json')['files'])
    require(bundle['cluster-inference'] == pins.native, 'Explicit native binary pin differs')
    for name in ('rank_worker.py', 'artifacts.py'):
        require(bundle[name] == sources['experiments/cluster/runtime/' + name], 'Bundle runtime differs from source')
    launcher = files(run / 'launcher', receipt['launcher_files'])
    require(launcher == {name: pin for name, pin in tested.items() if name.endswith('.py')},
            'Launcher archive differs from the prospectively tested source')
    require(sha(run / 'controls/control-manifest.json') == receipt['control_manifest_sha256'], 'Control manifest differs')
    controls = files(run / 'controls', read(run / 'controls/control-manifest.json')['files'])
    require(set(controls) == {'remote_prefill_control.py', 'prefill_compute_memory.py', 'artifacts.py', 'control-config.json'},
            'Control inventory differs')
    for name in ('remote_prefill_control.py', 'prefill_compute_memory.py'):
        require(controls[name] == tested[name], 'Staged control helper differs')
    require(controls['artifacts.py'] == bundle['artifacts.py'], 'Control artifact verifier differs')
    native = files(run, receipt['native_files'])
    caps = {'native/rank.json': 256 * 1024, 'native/stdout.jsonl': 8 * 1024**2, 'native/stderr.log': 64 * 1024}
    require(set(native) == set(caps) and (run / 'native/stderr.log').stat().st_size == 0, 'Native output inventory/stderr differs')
    for entry in receipt['native_files']:
        require(entry['maximum_bytes'] == caps[entry['path']] and type(entry['maximum_bytes']) is int
                and entry['hash_omitted_because_oversized'] is False and entry['size_bytes'] <= caps[entry['path']],
                'Native output cap/omitted-hash declaration differs')
    inputs = files(run, receipt['inputs']['files'])
    require(set(inputs) == {'inputs/prompt.json', 'inputs/prompt-origin.json'}, 'Unexpected input files')
    metadata = files(run, receipt['retrieved_remote_metadata'])
    require(set(metadata) == {'remote-metadata/' + name for name in ('before-config.json', 'before-manifest.json',
        'after-config.json', 'after-manifest.json', 'rank.final.json', 'prompt.final.json')}, 'Retrieved metadata differs')
    return dict(source=sources, bundle=bundle, launcher=launcher, controls=controls,
                native=native, inputs=inputs, metadata=metadata, dependencies=dependencies), bundle
