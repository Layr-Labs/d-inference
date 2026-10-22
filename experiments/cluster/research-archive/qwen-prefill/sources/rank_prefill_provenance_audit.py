"""CPU-only two-rank archive/resource checks; native output stays opaque."""
import copy
import hashlib
import importlib
import json
from pathlib import Path
import re
import sys


def archives(run, receipt, tests, binary, old, h):
    require, read, sha, files = h.require, h.read, h.sha, old.archive_files
    require(sha(run / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest differs')
    source = read(run / 'source-manifest.json')
    source_files = files(h, run / 'source', source['files'])
    require(type(receipt['source_file_count']) is int and 1 <= len(source_files) == receipt['source_file_count'] <= 1000, 'Source count differs')
    require(source['dependencies']['tracked_dependency_changes'] == ''
            and re.fullmatch('[0-9a-f]{40}', source['dependencies']['repository_head']) is not None, 'Dependency attestation differs')
    for line in source['dependencies']['submodules'].splitlines():
        require(re.match(r'^\s*[0-9a-f]{40}\s+\S+', line) is not None, 'Submodule identity malformed')
    require(sha(run / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest differs')
    bundle = files(h, run / 'bundle', read(run / 'bundle/bundle.json')['files'])
    bundle_map = {item['path']: item['sha256'] for item in bundle}
    require(bundle_map['cluster-inference'] == binary, 'Native binary pin differs')
    for name in ('artifacts.py', 'rank_worker.py'):
        require(bundle_map[name] == sha(run / 'source/experiments/cluster/runtime' / name), 'Bundle runtime differs from source')
    launcher = files(h, run / 'launcher', receipt['launcher_files'])
    tested = {item['path']: item['sha256'] for item in tests['source_files'] if item['path'].endswith('.py')}
    require({item['path']: item['sha256'] for item in launcher} == tested, 'Launcher differs from frozen 22-test source')
    require(sha(run / 'controls/control-manifest.json') == receipt['control_manifest_sha256'], 'Control manifest differs')
    controls = files(h, run / 'controls', read(run / 'controls/control-manifest.json')['files'])
    require({item['path'] for item in controls} == {'rank_prefill_control.py', 'prefill_compute_memory.py', 'artifacts.py', 'control-config.json'}, 'Control inventory differs')
    for name in ('rank_prefill_control.py', 'prefill_compute_memory.py'):
        require(sha(run / 'controls' / name) == tested[name], 'Control source differs')
    require(sha(run / 'controls/artifacts.py') == bundle_map['artifacts.py'], 'Control artifact verifier differs')
    ranks = files(h, run, receipt['rank_files'])
    require({item['path'] for item in ranks} == {f'rank-{rank}/{name}' for rank in range(2)
        for name in ('rank.json', 'stdout.jsonl', 'stderr.log')}, 'Rank file inventory differs')
    # Hash output bytes without parsing native numerical/action/timing records.
    return dict(source=source_files, bundle=bundle, launcher=launcher, controls=controls, rankFiles=ranks,
        inputs=files(h, run, receipt['inputs']['files']), metadata=files(h, run, receipt['retrieved_remote_metadata']),
        dependencyAttestation=source['dependencies']), bundle_map


def workload(run, receipt, binary, bundle_map, h):
    require, read, sha = h.require, h.read, h.sha
    sys.path.insert(0, str(run / 'launcher'))
    contract = importlib.import_module('rank_prefill_contract')
    inp = importlib.import_module('prefill_compute_inputs')
    prompt, endpoints, remote, epoch = receipt['inputs']['prompt'], receipt['hostfile'], receipt['remote_paths'], receipt['epoch']
    require(receipt['artifact_aggregate_sha256'] == inp.ARTIFACT and receipt['configuration_sha256'] == inp.CONFIGURATION, 'Artifact/configuration pin differs')
    contract.hostfile(endpoints)
    require(sha(run / 'inputs/origin-receipt.json') == inp.ORIGIN_RECEIPT and sha(run / 'inputs/expected-inventory.json') == inp.EXPECTED_INVENTORY,
            'Retained input/inventory source pins differ')
    origin = read(run / 'inputs/origin-receipt.json')
    require(receipt['inputs']['teacher'] == [] and read(run / 'inputs/prompt.json') == prompt
            == read(run / 'inputs/origin-prompt-65.json') == read(run / 'inputs/origin-prompt-96.json')[:65]
            == origin['tokenization']['prompt_ids'][:65]
            and sha(run / 'inputs/source-text.txt') == origin['tokenization']['source_text_sha256'], 'Prepared prose input differs')
    require(re.fullmatch('[0-9a-f]{32}', epoch) is not None and Path(remote['run']).name == epoch
            and remote['run'] == remote['root'] + '/' + epoch and remote['bundle'] == remote['run'] + '/bundle'
            and remote['controls'] == remote['run'] + '/controls'
            and remote['rank_directories'] == [remote['run'] + '/rank-' + str(i) for i in range(2)], 'Exclusive remote path layout differs')
    require(receipt['remote_port_reservation'] == dict(run=remote['run'], hostfile=endpoints, reservationOpen=False,
        method='remote_AF_INET_loopback_two_simultaneous_bind_then_close', raceFailsWithoutFallback=True), 'Port reservation attestation differs')
    prompt_hash = hashlib.sha256(json.dumps(prompt).encode()).hexdigest()
    hosts_hash = hashlib.sha256(json.dumps(endpoints).encode()).hexdigest()
    rank_pins = []
    for index, directory in enumerate(remote['rank_directories']):
        expected = contract.configuration(Path(remote['bundle']), receipt['bundle_manifest_sha256'], Path(remote['model']),
            prompt, 180, index, epoch, receipt['stage_prefill_policy'], endpoints)
        original = run / f'rank-{index}/rank.json'; copied = run / f'remote-metadata/rank-{index}-rank.json'
        require(read(original) == read(copied) == expected and sha(original) == receipt['rank_configuration_sha256'][index], 'Exact rank configuration differs')
        require(sha(run / f'remote-metadata/rank-{index}-prompt.json') == prompt_hash
                and sha(run / f'remote-metadata/rank-{index}-hosts.json') == hosts_hash, 'Remote staged input bytes differ')
        rank_pins.append(dict(rank=index, directory=directory, rank_sha256=sha(original), prompt_sha256=prompt_hash, hostfile_sha256=hosts_hash))
    expected_controls = dict(remote, run_id=epoch, ranks=rank_pins, bundle_sha256=receipt['bundle_manifest_sha256'],
        binary_sha256=binary, artifact_sha256=inp.ARTIFACT, configuration_sha256=inp.CONFIGURATION)
    require(read(run / 'controls/control-config.json') == expected_controls, 'Pinned controls do not bind both exact ranks')
    for phase in ('before', 'after'):
        result = receipt['remote_' + phase]
        require(result['artifact_aggregate_sha256'] == inp.ARTIFACT and result['bundle_manifest_sha256'] == receipt['bundle_manifest_sha256']
                and result['bundle_file_sha256'] == bundle_map and [r['rank'] for r in result['ranks']] == [0, 1], 'Remote artifact/bundle attestation differs')
        for index, observed in enumerate(result['ranks']):
            expected = dict(rank=index, rank_configuration_sha256=rank_pins[index]['rank_sha256'])
            if phase == 'after': expected.update(prompt_sha256=prompt_hash, hostfile_sha256=hosts_hash)
            require(observed == expected, 'Remote rank verification attestation differs')
        for name in ('config.json', 'manifest.json'):
            item = result['model_metadata'][name]; local = run / 'remote-metadata' / (phase + '-' + name)
            require(item == dict(remote_path=remote['run'] + '/metadata/' + phase + '-' + name,
                sha256=sha(local), size_bytes=local.stat().st_size), 'Fetched model metadata differs')
    for name in ('config.json', 'manifest.json'):
        require(sha(run / 'remote-metadata' / ('before-' + name)) == sha(run / 'remote-metadata' / ('after-' + name)), 'Remote metadata changed')
    require(sha(run / 'remote-metadata/before-config.json') == inp.CONFIGURATION, 'Remote config pin differs')
    manifest = read(run / 'remote-metadata/before-manifest.json'); declared = {row['path']: row for row in manifest['files']}
    aggregate = hashlib.sha256(b''.join(bytes.fromhex(declared[name]['sha256']) for name in sorted(declared))).hexdigest()
    require(len(declared) == len(manifest['files']) == manifest['file_count']
            and sum(row['size_bytes'] for row in declared.values()) == manifest['total_size_bytes'] == 6113952230
            and aggregate == manifest['aggregate_sha256'] == inp.ARTIFACT, 'Retained manifest declaration differs')
    return dict(policy=receipt['stage_prefill_policy'], epoch=epoch, exactRankArgumentsVerified=True,
        sharedRemoteModelPath=remote['model'], modelPayloadBytesRead=0, declaredArtifactPayloadBytes=manifest['total_size_bytes'],
        remoteBeforeAfterArtifactAttestationsMatch=True, endpointPair=endpoints, endpointsWereNotHeldThroughLaunch=True,
        stdoutSHA256=[sha(run / f'rank-{i}/stdout.jsonl') for i in range(2)], nativeOutputRecordsParsed=False)


def resources_and_controls(run, receipt, shared, h):
    require, read, sha = h.require, h.read, h.sha
    # Reuse the vetted single-rank arithmetic separately for each observed rank.
    # Remove only the new explicit rank tag after validating it; never discard
    # an unknown rank or substitute a zero RSS value for a missing observation.
    samples = receipt['remote_memory_samples']; require(samples, 'No memory samples')
    simultaneous = []
    for index, sample in enumerate(samples):
        rows = sample['remote_pid_inventory']['observed_processes']
        require(len(rows) <= 16 and all(type(row.get('rank')) is int and row['rank'] in (0, 1) for row in rows), 'Invalid observed rank')
        for rank in range(2):
            for kind in ('native', 'supervisor'):
                require(sum(row['rank'] == rank and row['kind'] == kind for row in rows) <= 1, 'Duplicate observed native/supervisor for one rank')
        native = [row for row in rows if row['kind'] == 'native']
        if len(native) == 2:
            require({row['rank'] for row in native} == {0, 1}, 'Simultaneous native observations lack one rank')
            simultaneous.append(dict(sampleIndex=index, nativePIDs=[row['pid'] for row in sorted(native, key=lambda row: row['rank'])],
                                     summedNativeRSSBytes=sum(row['rssBytes'] for row in native)))
    require([item['rank'] for item in receipt['observed_remote_processes']] == [0, 1], 'Observed rank summary differs')
    per_rank = []
    for rank in range(2):
        view = copy.deepcopy(receipt)
        view['remote_paths']['native'] = receipt['remote_paths']['rank_directories'][rank]
        view['observed_remote_native_pids'] = receipt['observed_remote_processes'][rank]['native_pids']
        view['observed_remote_supervisor_pids'] = receipt['observed_remote_processes'][rank]['supervisor_pids']
        for sample in view['remote_memory_samples']:
            inventory = sample['remote_pid_inventory']
            inventory['observed_processes'] = [{key: value for key, value in row.items() if key != 'rank'}
                for row in inventory['observed_processes'] if row['rank'] == rank]
        per_rank.append(dict(rank=rank, validation=shared.validate_resources(view)))
    # Preserve original bytes/hashes while adapting only the known namespace
    # expected by the established control sequence checker.
    def read_control(path):
        item = read(path); require(item['record']['kind'] == 'rank_prefill_control', 'Control namespace differs')
        adapted = copy.deepcopy(item); adapted['record']['kind'] = 'remote_prefill_control'; return adapted
    sequence = shared.controls_sequence(run / 'remote-observations', dict(receipt, run_id=receipt['epoch']), read_control, sha)
    return dict(samples=len(samples), perRank=per_rank, simultaneousNativeSamples=simultaneous,
        simultaneousNativeSampleCount=len(simultaneous), maximumSimultaneouslyObservedNativeRSSBytes=max(
            (row['summedNativeRSSBytes'] for row in simultaneous), default=None), supervisorsExcludedFromNativeSum=True,
        sampledRSSIsNotPeak=True, missingRSSNotAssumedZero=True, rawPsRSSIndependentlyReconstructed=False,
        crossProcessMonotonicOrderingAsserted=False), sequence
