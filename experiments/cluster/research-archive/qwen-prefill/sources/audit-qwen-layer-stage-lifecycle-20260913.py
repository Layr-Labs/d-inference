#!/usr/bin/env python3
"""Bounded CPU audit of archived tiny-stage lifecycle results; no native/model IO."""
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
FAILED = ROOT / 'runs/qwen-layer-stage-lifecycle-20260913'
FIXED = ROOT / 'runs/qwen-layer-stage-lifecycle-fix1-20260913'
ORIGINAL = ROOT / 'runs/qwen-layer-stage-runtime-20260913'
HELPER = ROOT / 'audit-qwen-layer-stage-runtime-20260913.py'
HELPER_SHA = '08bba80ad29f1ebfe486286419d188922b2f08bb09aff21c72a10bc46e1197bf'
OUTPUT = ROOT / 'qwen-layer-stage-lifecycle-independent-cpu-audit-20260913.json'
PINS = {
    FAILED: ('27e28b92f7c45ef234a188a7ccd181425dda5ac0ea2499011649594421b093d6',
             'e26227ea0e6f9e899cc6d69c0a4ea9ff1112102a4bce9e1c2565bda934ad88ae', 183, 1),
    FIXED: ('f8e36e71993416c88559b56530ed27825303e8f70caead68908a3c2b54256d7d',
            '9cdfbaa7d47b0b566b8623f0ca984ff28803d8b2bfb2696384b93d8e6d0d2c60', 184, 0),
}
SWIFT = 'experiments/cluster/inference/Sources/ClusterInference/'
LIFECYCLE = SWIFT + 'QwenLayerStageLifecycleCheck.swift'


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == HELPER_SHA
h = load_module('frozen_stage_metadata_audit', HELPER)
require, sha, read, parse = h.require, h.sha, h.read, h.parse


def archive(run):
    receipt_pin, binary_pin, source_count, exit_code = PINS[run]
    require(sha(run / 'receipt.json') == receipt_pin, 'Run receipt differs from terminal pin')
    receipt = read(run / 'receipt.json')
    require(receipt['status'] == ('completed' if exit_code == 0 else 'failed')
        and receipt['expected_native_sha256'] == binary_pin and len(receipt['native_calls']) == 1,
        'Run completion identity differs')
    for name, expected in receipt['driver_files_sha256'].items():
        require(sha(run / name) == expected, 'Archived driver/helper changed')
    require(sha(run / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest changed')
    source = read(run / 'source-manifest.json')
    require(len(source) == len({item['path'] for item in source}) == source_count, 'Source inventory differs')
    for item in source:
        path = run / 'source' / item['path']
        require(path.stat().st_size == item['size_bytes'] and sha(path) == item['sha256'], 'Archived source changed')
    require(sha(run / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest changed')
    bundle = read(run / 'bundle/bundle.json')['files']
    require(len(bundle) == len({item['path'] for item in bundle}) == len(receipt['bundle_files']), 'Bundle inventory differs')
    for item in bundle:
        path = run / 'bundle' / item['path']
        require(path.stat().st_size == item['size_bytes'] and sha(path) == item['sha256']
            == receipt['bundle_files'][item['path']], 'Archived executable/bundle changed')
    require(receipt['bundle_files']['cluster-inference'] == binary_pin, 'Tested binary differs')
    call = receipt['native_calls'][0]
    expected_argv = [str(run / 'bundle/cluster-inference'), '--mode', 'qwen-layer-stage-check', '--synthetic',
        '--execution-path', 'cbv2-contiguous', '--prompt-tokens', '65', '--chunk-size', '32', '--decode-tokens', '4',
        '--repeats', '1', '--warmups', '0', '--timeout-seconds', '170']
    require(call['command'] == expected_argv and call['exit_code'] == exit_code
        and call['outer_timeout_seconds'] == 195 and 0 < call['wall_seconds'] < 195, 'Native argv/exit/deadline differs')
    cleanup = call['cleanup']
    require(cleanup['all_observed_owned_processes_exited'] is True and cleanup['launcher_reaped'] is True
        and cleanup['cancel_files_requested'] is bool(exit_code), 'Saved cleanup differs')
    require(sha(run / 'native/stdout.txt') == call['stdout_sha256']
        and sha(run / 'native/stderr.txt') == call['stderr_sha256'], 'Native output changed')
    if exit_code == 0:
        require(receipt['native_records_sha256'] == call['stdout_sha256'], 'Completed record hash differs')
        require(re.fullmatch(r'\[bf16\] converted 124 params \(0\.1 MB\) fp16→bf16 in \d+ ms\n',
            (run / 'native/stderr.txt').read_text()), 'Unexpected completed stderr')
    states = [call['preflight'], *call['memory_samples']]
    require(call['preflight']['passed'] is True, 'Preflight failed')
    if exit_code == 0:
        require(call['postflight']['passed'] is True, 'Completed postflight failed')
        states.append(call['postflight'])
    else:
        require('postflight' not in call, 'Unexpected failed-run postflight')
    for state in states:
        require(state['memory_pressure_level'] == 2 and state['severe_pressure'] is False, 'Recorded pressure differs')
        require(state['swap_used_bytes'] == states[0]['swap_used_bytes'], 'New swap observed')
        used = re.search(r'used = ([0-9.]+)M', state['swap_usage'])
        require(used and round(float(used[1]) * 1024**2) == state['swap_used_bytes'], 'Swap text/numeric mismatch')
        pages = {name: int(re.search(r'^Pages ' + name + r':\s+(\d+)\.', state['vm_stat'], re.M)[1])
            for name in ['free', 'inactive', 'speculative']}
        require(sum(pages.values()) * state['page_size_bytes'] == state['estimated_reclaimable_bytes'],
            'Reclaimable estimate differs from saved vm_stat')
    require(call['peak_observed_owned_rss_bytes'] >= max(s['owned_process_rss_bytes'] for s in call['memory_samples']),
        'Observed RSS peak below sample')
    lines = (run / 'native/stdout.txt').read_text().splitlines()
    require(all(line.startswith('{') for line in lines), 'Unexpected non-record stdout')
    rows = [parse(line) for line in lines]
    return receipt, {item['path']: item for item in source}, rows, dict(
        run_directory=str(run), terminal_receipt_sha256=receipt_pin, native_exit_code=exit_code,
        tested_binary_sha256=binary_pin, archived_source_manifest_sha256=receipt['source_manifest_sha256'],
        archived_source_entries_verified=source_count, archived_bundle_manifest_sha256=receipt['bundle_manifest_sha256'],
        archived_bundle_files_verified=len(bundle), native_stdout_sha256=call['stdout_sha256'],
        native_stderr_sha256=call['stderr_sha256'], record_count=len(rows), argv_verified=True,
        all_observed_owned_processes_exited=True, launcher_reaped=True,
        cancellation_requested=cleanup['cancel_files_requested'],
        resources=dict(sample_count=len(call['memory_samples']), pressure_levels=[2], new_swap_bytes=0,
            starting_swap_bytes=states[0]['swap_used_bytes'], postflight_present='postflight' in call,
            peak_observed_owned_rss_bytes=call['peak_observed_owned_rss_bytes'], whole_process_peak_not_proven=True))


def main():
    require(not OUTPUT.exists(), 'Preserve existing audit receipt')
    failed, old_source, failed_rows, failure_provenance = archive(FAILED)
    fixed, new_source, rows, fixed_provenance = archive(FIXED)
    require(failed['driver_files_sha256'] == fixed['driver_files_sha256'], 'Failure and corrected drivers differ')
    added = sorted(set(new_source) - set(old_source))
    removed = sorted(set(old_source) - set(new_source))
    changed = sorted(k for k in set(old_source) & set(new_source) if old_source[k] != new_source[k])
    require(added == ['experiments/cluster/inference/QWEN_LAYER_STAGE_VALIDATION.md'] and not removed
        and changed == ['experiments/cluster/inference/README.md', LIFECYCLE], 'Unexpected failure-to-fix source changes')
    old = (FAILED / 'source' / LIFECYCLE).read_text()
    new = (FIXED / 'source' / LIFECYCLE).read_text()
    require(old.count('.contains("closed")') == 1
        and old.replace('.contains("closed")', '.contains("CBv2 state is retired")') == new,
        'Executable source correction is not the expected error string only')
    # Bind unchanged state/loader/parity oracles to the previous independently reviewed archive.
    original_audit = ORIGINAL / 'independent-cpu-audit.json'
    require(sha(original_audit) == '53f2bb6cee306e2e7b056dba98257cac049f1a1cbea0b8c0ce5c3abeb43a3991',
        'Previous independent audit changed')
    prior = read(original_audit)
    require(sha(ORIGINAL / 'source-manifest.json') == prior['archived_source_manifest_sha256'], 'Original manifest changed')
    original_source = {item['path']: item for item in read(ORIGINAL / 'source-manifest.json')}
    swift_changed = sorted(k for k in set(original_source) & set(new_source)
        if k.endswith('.swift') and original_source[k] != new_source[k])
    require(swift_changed == [SWIFT + 'QwenLayerStageBoundary.swift', SWIFT + 'QwenLayerStageSelfCheck.swift'],
        'Previously reviewed loader/state/parity implementation changed')
    boundary_old = (ORIGINAL / 'source' / swift_changed[0]).read_text()
    boundary_new = (FIXED / 'source' / swift_changed[0]).read_text()
    require(re.sub(r'\s+', '', boundary_old) == re.sub(r'\s+', '', boundary_new), 'Boundary change is not whitespace only')
    self_old = (ORIGINAL / 'source' / swift_changed[1]).read_text()
    self_new = (FIXED / 'source' / swift_changed[1]).read_text()
    lifecycle_call = '            try emitJSON(checkQwenLayerStageLifecycle(fixture: fixture, proof: proof,\n                options: fixtureOptions, check: check))\n'
    require(self_new.count(lifecycle_call) == 1 and self_new.replace(lifecycle_call, '') == self_old,
        'Self-check changed beyond adding lifecycle execution')
    sys.path.insert(0, str(FIXED))
    driver = load_module('frozen_lifecycle_driver', FIXED / 'validate-qwen-layer-stage.py')
    require(driver.check_records(rows) == fixed['fixtures'], 'Archived driver validation differs')
    require(sha(h.BASE_ORACLE) == h.BASE_ORACLE_SHA, 'Raw floating-byte oracle changed')
    raw = load_module('frozen_stage_raw_float_oracle', h.BASE_ORACLE)
    fixtures = []
    for index, (dtype, wrapped, fp16) in enumerate([
            ('float32', False, False), ('bfloat16', True, False), ('bfloat16', True, True)]):
        loader, parity, lifecycle = rows[index * 3:index * 3 + 3]
        recovered = lifecycle['recoveryOnSameResidentModels']
        require(recovered == parity, 'Recovery emitted record differs from original request')
        initial = h.fixture_metadata(loader, parity, dtype, wrapped, fp16, raw)
        recovery = h.fixture_metadata(loader, recovered, dtype, wrapped, fp16, raw)
        require(recovery == initial, 'Independent recovery metadata/raw-logit validation differs')
        fixtures.append(dict(dtype=dtype, wrapped=wrapped, fp16_layer_metadata=fp16,
            active_tensors_per_stage=[118, 119], active_tensor_bytes=initial['active_tensor_bytes'],
            inert_tensor_bytes=initial['inert_tensor_bytes'], source_tensor_bytes=initial['source_tensor_bytes'],
            frames_per_request=6, state_entries_per_frame=18, logits_rows_per_request=4,
            faulted_frontiers=lifecycle['failedStageFrontiers'], retired_request_reuse_rejections=2,
            recovery_record_exactly_equals_original=True,
            candidate_logits_logical_bytes_cpu_verified_initial_and_recovery=True))
    require(len(failed_rows) == 2 and failed_rows[0]['kind'] == 'qwen_layer_stage_loader_check'
        and failed_rows[1]['kind'] == 'qwen_layer_stage_parity_check', 'Failed run progressed beyond preserved evidence')
    h.fixture_metadata(failed_rows[0], failed_rows[1], 'float32', False, False, raw)
    expected_failure = 'cluster-inference: Retired stage reuse failed for an unexpected reason: CBv2 state is retired, failed or has unfinished work\n'
    require((FAILED / 'native/stderr.txt').read_text() == expected_failure
        and failed['error'] == 'ValueError: Inference launcher failed with exit 1', 'Failure diagnosis differs')
    failure_provenance.update(status='failed_preserved', cause='Test required closed substring; runtime correctly rejected retired state with a different message.',
        original_f32_loader_and_parity_emitted=True, complete_lifecycle_record_emitted=False,
        recovery_request_executed=False,
        source_review_inference='The emitted error is after the guard requiring committed frontiers [32,0] and both states failed/closed; the reuse assertion fails on its first iteration.',
        executable_source_fix='One assertion substring changed from closed to CBv2 state is retired.')
    for run, (receipt_pin, _, _, _) in PINS.items():
        require(sha(run / 'receipt.json') == receipt_pin, 'Historical receipt changed during audit')
    result = dict(schema_version=1, status='passed_for_corrected_run', cpu_only=True,
        audit_kind='archived_stage_lifecycle_metadata_raw_logits_and_source_review',
        audited_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), audit_script_sha256=sha(__file__),
        metadata_helper_sha256=HELPER_SHA, floating_byte_helper_sha256=h.BASE_ORACLE_SHA,
        prior_independent_runtime_audit_sha256=sha(original_audit), corrected_run=fixed_provenance,
        preserved_failed_run=failure_provenance,
        failure_to_fix_source_changes=dict(added=added, removed=removed, changed=changed,
            executable_source_change_is_assertion_substring_only=True), fixtures=fixtures,
        independent_cpu_checks=dict(active_descriptors=711, original_and_recovery_state_geometry_frames=36,
            original_and_recovery_candidate_logit_rows=24, paired_recovery_vs_original_records=3,
            separately_checked_failed_run_active_descriptors=237, separately_checked_failed_run_logit_rows=4),
        native_executions_by_audit=0, model_payload_reads_by_audit=0,
        source_review_conclusion='No obvious loader/parity/lifecycle oracle error found after the assertion fix. Recovery constructs fresh state owners on the same resident model objects and compares complete committed state and output rows against a fresh ordinary baseline request.',
        limitations=[
            'Tiny eight-layer, sequential single-process correctness only; no real-model, throughput or physical two-machine qualification.',
            'Active parameter equality/uniqueness, source-file independence and paired baseline/stage state/logit equality are native assertions bound to archived source and the tested executable; raw paired arrays are not archived.',
            'CPU audit independently derives tensor/state geometry and accounting, verifies emitted candidate logit logical bytes/hashes and exact initial/recovery record equality. Full-state hashes remain opaque native commitments.',
            'Only final-prefill and decode logit values are compared; intermediate evaluation handles are checked for geometry/dtype and complete committed state.',
            'Failure-run recovery never executed and its postflight resource sample is absent. Saved cleanup shows the launcher reaped and all observed owned processes exited.',
            'Saved resource samples show no new swap or severe pressure at observed times; sampling does not prove whole-process peak memory.',
            'Archived sources and executable are associated by the root launch receipt; this CPU audit does not reproduce the native build.'
        ])
    with OUTPUT.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write('\n')
    print(json.dumps(dict(status=result['status'], output=str(OUTPUT), output_sha256=sha(OUTPUT),
        script_sha256=sha(__file__), corrected_records=9, independent_candidate_logit_rows=24,
        failed_run_preserved=True, native_executions=0), sort_keys=True))


if __name__ == '__main__':
    main()
