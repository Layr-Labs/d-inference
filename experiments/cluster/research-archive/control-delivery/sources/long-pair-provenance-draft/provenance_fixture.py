"""Invented complete CPU archive; never native or tokenization evidence."""
import copy
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
from long_reference_provenance_common import Pins, sha
from long_reference_provenance_records import ENVIRONMENT, expected_rank


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')


def entry(base, path):
    return dict(path=path.relative_to(base).as_posix(), sha256=sha(path), size_bytes=path.stat().st_size)


def make_fixture(base):
    run, origin, review_dir = base / 'run', base / 'origin', base / 'review'
    for folder in (run, origin, review_dir): folder.mkdir()
    prompt = ('[' + ','.join(['3'] * 8192) + ']\n').encode()
    for name, data in [('prompt-8192.json', prompt), ('source-text.txt', b'prose'),
                       ('decoded-prefix.txt', b'prefix'), ('preparation.py', b'# source only')]: (origin / name).write_bytes(data)
    token_hash = hashlib.sha256(b'tokenizer').hexdigest()
    logical = hashlib.sha256(','.join(['3'] * 8192).encode()).hexdigest()
    tokenization = dict(kind='long_prefill_prose_input', schemaVersion=1, promptCount=8192,
        vocabularySize=248320, promptTokenIDsSHA256=logical, addSpecialTokens=False,
        chatTemplateApplied=False, representativeWorkloadClaim=False, modelInferencePerformed=False,
        tokenizerJSONSHA256=token_hash,
        files={p.name: dict(byteCount=p.stat().st_size, sha256=sha(p)) for p in origin.iterdir()})
    write(origin / 'tokenization.json', tokenization)
    config = b'{"fake_configuration":1}\n'
    aggregate = hashlib.sha256(bytes.fromhex(token_hash)).hexdigest()
    manifest = dict(files=[dict(path='tokenizer.json', size_bytes=9, sha256=token_hash)], file_count=1,
                    total_size_bytes=9, aggregate_sha256=aggregate)
    manifest_raw = (json.dumps(manifest) + '\n').encode()
    rid = '1' * 32; remote_run = '/owned/' + rid
    remote = dict(root='/owned', run=remote_run, native=remote_run + '/native', controls=remote_run + '/controls',
                  bundle=remote_run + '/native/bundle', model='/model')
    runtime = run / 'source/experiments/cluster/runtime'; runtime.mkdir(parents=True)
    for name in ('rank_worker.py', 'artifacts.py', 'processes.py'): (runtime / name).write_text('# frozen fake ' + name)
    source_entries = [entry(run / 'source', p) for p in sorted(runtime.iterdir())]
    write(run / 'source-manifest.json', dict(files=source_entries, dependencies=dict(
        repository_head='2' * 40, tracked_dependency_changes='', submodules='3' * 40 + ' libs/fake\n')))
    bundle = run / 'bundle'; bundle.mkdir()
    (bundle / 'cluster-inference').write_bytes(b'non executable CPU fixture')
    for name in ('rank_worker.py', 'artifacts.py'): (bundle / name).write_bytes((runtime / name).read_bytes())
    bundle_entries = [entry(bundle, p) for p in sorted(bundle.iterdir())]
    write(bundle / 'bundle.json', dict(files=bundle_entries))
    pins = Pins(sha(bundle / 'cluster-inference'), aggregate, hashlib.sha256(config).hexdigest(),
                sha(origin / 'prompt-8192.json'), sha(origin / 'tokenization.json'))
    receipt = dict(kind='remote_qwen_long_prefill_pair_launcher', schema_version=1,
        run_id=rid, execution_host='fixture-peer', remote_paths=remote, passed=True,
        native_execution_attempted=True, full_reference_forward_requested=True,
        source_bundle_raw_inputs_and_remote_model_unchanged_after_run=True,
        remote_pid_observations_are_not_reaping_proof=True, physical_two_machine_execution=False,
        interprocess_model_transport=False, throughput_qualification=False, independent_reference_oracle_run=False,
        local_model_payload_verified=False, stage_model_forward_requested=True, timing_requested=False,
        expected_native_sha256=pins.native, artifact_aggregate_sha256=pins.artifact, configuration_sha256=pins.configuration,
        native_process_count=1, native_timeout_seconds=300, parent_timeout_seconds=330,
        primary_failure=None, cleanup_errors=[], post_run_errors=[], source_file_count=len(source_entries),
        source_manifest_sha256=sha(run / 'source-manifest.json'), bundle_manifest_sha256=sha(bundle / 'bundle.json'),
        execution=dict(passed=True, exit_code=0, local_ssh_client_reaped=True, local_ssh_client_pid=77,
            remote_process_reaping_independently_verified=False, independent_comparison_oracle_run=False,
            validated_outer_records=2, error=None, cancellation_reason=None, cleanup_errors=[]))
    inputs = run / 'inputs'; inputs.mkdir()
    (inputs / 'prompt.json').write_bytes(prompt); (inputs / 'prompt-origin.json').write_bytes((origin / 'tokenization.json').read_bytes())
    receipt['inputs'] = dict(prompt=[3] * 8192, teacher=[], prompt_file_sha256=pins.prompt,
        prompt_origin_file_sha256=pins.origin, prompt_token_ids_sha256=logical, raw_prompt_reencoded=False,
        prompt_origin_schema_audited_by_launcher=False, files=[entry(run, p) for p in sorted(inputs.iterdir())])
    native = run / 'native'; native.mkdir(); write(native / 'rank.json', expected_rank(receipt, pins))
    (native / 'stdout.jsonl').write_bytes(b'{"opaque":true}\n{"opaque":true}\n'); (native / 'stderr.log').write_bytes(b'')
    receipt['rank_configuration_sha256'] = sha(native / 'rank.json')
    caps = {'rank.json': 262144, 'stdout.jsonl': 8 * 1024**2, 'stderr.log': 65536}
    receipt['native_files'] = [dict(entry(run, p), maximum_bytes=caps[p.name], hash_omitted_because_oversized=False)
                               for p in sorted(native.iterdir())]
    launcher = run / 'launcher'; launcher.mkdir()
    for name in ('remote_prefill_control.py', 'prefill_compute_memory.py', 'launch.py'):
        (launcher / name).write_text('# tested fake ' + name)
        (review_dir / name).write_bytes((launcher / name).read_bytes())
    receipt['launcher_files'] = [entry(launcher, p) for p in sorted(launcher.iterdir())]
    review = review_dir / 'source-review.json'
    write(review, dict(kind='remote_registered9b_long_pair_launcher_source_freeze',
        prospective_cpu_tests=dict(passed=True, count=8, python39_syntax_all_files_passed=True),
        native_execution_performed=False, candidate_output_accessed=False,
        files=[dict(entry(review_dir, p), path=str(p)) for p in sorted(review_dir.iterdir())],
        repository_dependencies={x['path']: x['sha256'] for x in source_entries}))
    controls = run / 'controls'; controls.mkdir()
    for name in ('remote_prefill_control.py', 'prefill_compute_memory.py'): (controls / name).write_bytes((launcher / name).read_bytes())
    (controls / 'artifacts.py').write_bytes((bundle / 'artifacts.py').read_bytes())
    write(controls / 'control-config.json', dict(remote, run_id=rid, bundle_sha256=receipt['bundle_manifest_sha256'],
        binary_sha256=pins.native, rank_sha256=receipt['rank_configuration_sha256'], artifact_sha256=pins.artifact,
        configuration_sha256=pins.configuration, prompt_sha256=pins.prompt, prompt_size_bytes=len(prompt), required_environment=ENVIRONMENT))
    write(controls / 'control-manifest.json', dict(files=[entry(controls, p) for p in sorted(controls.iterdir())]))
    receipt['control_manifest_sha256'] = sha(controls / 'control-manifest.json')
    metadata = run / 'remote-metadata'; metadata.mkdir()
    for phase in ('before', 'after'):
        for name, data in [('config.json', config), ('manifest.json', manifest_raw)]: (metadata / (phase + '-' + name)).write_bytes(data)
    (metadata / 'rank.final.json').write_bytes((native / 'rank.json').read_bytes()); (metadata / 'prompt.final.json').write_bytes(prompt)
    receipt['retrieved_remote_metadata'] = [entry(run, p) for p in sorted(metadata.iterdir())]
    vm = 'Mach Virtual Memory Statistics: (page size of 4096 bytes)\nPages free: 2000000.\nPages inactive: 1000000.\nPages speculative: 100000.\n'
    initial = dict(phase='remote_before_bundle_staging_and_remote_artifact_hashing', passed=True, vm_stat=vm,
        actual_free_bytes=8192000000, estimated_reclaimable_bytes=12697600000, required_actual_free_bytes=6 * 1024**3,
        guarantees_six_gib_free_at_native_launch=False, timestamp_utc='2026-09-14T00:00:00+00:00', monotonic_seconds=1)
    pre = dict(initial, phase='after_artifact_hashing_before_native', required_reclaimable_bytes=8 * 1024**3,
        disk_free_bytes=8 * 1024**3, required_disk_free_bytes=4 * 1024**3, estimate_is_not_memory_guarantee=True,
        nofile_soft=1024, open_descriptors=4)
    memory = dict(monotonic_seconds=1, pressure_level=1, swap_used_bytes='0', raw_sysctl='1\nused = 0.00M\n',
        remote_pid_inventory=dict(exact_run_path_match=True, observation_is_not_waitpid_or_remote_reaping_proof=True,
            rss_is_sampled_not_peak=True, missing_process_rss_is_not_assumed_zero=True, observed_processes=[]))
    for phase in ('before', 'after'):
        record = dict(artifact_aggregate_sha256=pins.artifact, bundle_manifest_sha256=receipt['bundle_manifest_sha256'],
            bundle_file_sha256={x['path']: x['sha256'] for x in bundle_entries}, rank_configuration_sha256=receipt['rank_configuration_sha256'],
            prompt_sha256=pins.prompt, prompt_size_bytes=len(prompt), raw_prompt_reencoded=False, memory=copy.deepcopy(memory),
            model_metadata={name: dict(sha256=sha(metadata / (phase + '-' + name)), size_bytes=(metadata / (phase + '-' + name)).stat().st_size,
                remote_path=remote_run + '/metadata/' + phase + '-' + name) for name in ('config.json', 'manifest.json')})
        if phase == 'before': record['posthash_preflight'] = pre
        receipt['remote_' + phase] = record
    receipt.update(remote_initial_free_screen=initial, remote_memory_samples=[copy.deepcopy(memory) for _ in range(3)],
                   observed_remote_native_pids=[], observed_remote_supervisor_pids=[])
    for index, (operation, result) in enumerate([('initial', initial), ('before', receipt['remote_before']),
                                               ('observe', memory), ('after', receipt['remote_after'])], 1):
        write(run / 'remote-observations' / ('%04d-%s.json' % (index, operation)), dict(operation=operation,
            timeout_seconds=3, passed=True, record=dict(kind='remote_prefill_control', schema_version=1,
                operation=operation, run_id=rid, remote_run=remote_run, result=result)))
    write(run / 'receipt.json', receipt)
    source_folder = Path(__file__).parent
    names = ['postflight_remote_long_pair.py', 'long_reference_postflight_payload.py',
             'long_reference_provenance_common.py', 'long_reference_provenance_records.py']
    post = base / 'postflight.json'
    write(post, dict(kind='root_remote_long_pair_postflight', schemaVersion=1, passed=True,
        launcherReceiptSHA256=sha(run / 'receipt.json'), sourceSHA256={name: sha(source_folder / name) for name in names},
        runID=rid, nativeBinarySHA256=pins.native, localSSHClientPID=77, localSSHClientReaped=True,
        remoteReapingIndependentlyProven=False, remoteWorkerCleanupSourceBound=True, liveRepositoryCompared=False,
        rootLauncherTerminalExitCode=0, sshExitCode=0, sshStderr='', cleanupSourceSHA256={name: sha(runtime / name)
            for name in ('rank_worker.py', 'processes.py')}, observation=dict(ownedLiveProcesses=[], remoteRun=remote_run,
                timestampUTC='2026-09-14T00:00:00+00:00', memory='1\nused = 0.00M\n')))
    return SimpleNamespace(run=run, origin=origin, review=review, review_sha=sha(review), pins=pins, postflight=post)
