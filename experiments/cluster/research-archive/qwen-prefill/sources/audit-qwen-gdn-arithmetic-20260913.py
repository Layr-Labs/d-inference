#!/usr/bin/env python3
"""Replay archived arithmetic evidence on CPU; never launch native/model code."""
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import sys

sys.dont_write_bytecode = True
RESEARCH = Path('/Users/developer/DarkbloomDev/cluster-research')
RUN = RESEARCH / 'runs/qwen-gdn-arithmetic-20260913'
PRIOR = RESEARCH / 'runs/qwen-gdn-input-20260913'
MODEL = Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B')
NATIVE = '3896e9401fba1d629a184eeb695a6539d252361b894b8b028fb6011806de26f8'
AGGREGATE = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
CONFIG = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
RECEIPT = 'a5fd2202588a70f37636e05540fa82601a27801ef0564d32e01e6314cac756e2'
PRIOR_AUDIT = '7e5e736f060b49d71d65cbabcf4ab32415a1fa0750e5dc43634a949fa4abee1a'
ORACLE = '4f6b60bdc04cd962e9c41e26d0ce649f9559e151ded57b73d9c8bda7c36b65ec'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def read(path):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs,
        parse_int=lambda value: -0.0 if value == '-0' else int(value),
        parse_constant=lambda value: require(False, 'Nonfinite JSON'))


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    sys.modules[name] = result
    spec.loader.exec_module(result)
    return result


def archived_bindings(receipt):
    require(sha(RUN / 'receipt.json') == RECEIPT and receipt['status'] == 'completed'
        and receipt['all_execution_and_identity_checks_passed'] is True, 'Completion receipt differs')
    require(receipt['expected_native_sha256'] == NATIVE and receipt['expected_aggregate_sha256'] == AGGREGATE,
        'Tested binary/artifact identity differs')
    require(sha(RUN / 'qwen_gdn_arithmetic_audit.py') == ORACLE, 'Tested arithmetic oracle differs')
    for name, expected in receipt['driver_files_sha256'].items():
        require(sha(RUN / name) == expected, 'Archived driver/helper differs: ' + name)
    require(sha(RUN / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest differs')
    entries = read(RUN / 'source-manifest.json')
    require(len(entries) == len({item['path'] for item in entries}) == 160, 'Source inventory differs')
    for item in entries:
        path = RUN / 'source' / item['path']
        require(path.is_relative_to(RUN / 'source') and path.stat().st_size == item['size_bytes']
            and sha(path) == item['sha256'], 'Archived source differs: ' + item['path'])
    for name, expected in receipt['input_files_sha256'].items():
        require(sha(RUN / name) == expected, 'Archived input differs: ' + name)
    require(sha(RUN / 'model-manifest.json') == receipt['model_manifest_sha256'] == sha(MODEL / 'manifest.json')
        and sha(MODEL / 'config.json') == CONFIG, 'Current model manifest/config differs')
    require(sha(PRIOR / 'independent-cpu-audit.json') == PRIOR_AUDIT, 'Prior raw-input audit differs')
    require(all(item['status'] == '' for item in receipt['dependencies'].values()), 'Saved dependencies dirty')
    expected_heads = {
        'libs/mlx-swift-lm': 'ce446cc5f76e013855fe0bde9002b6db1ac091b7',
        'libs/mlx-swift': '6d6796d7a81b656d2749d39067e0a6bea2bc2986',
        'libs/mlx-swift/Source/Cmlx/mlx': '3fa8f25e6451174d7b06be372c3a24272b77d88e'}
    require({name: value['head'] for name, value in receipt['dependencies'].items()} == expected_heads,
        'Saved dependency pins differ')


def check_commands(receipt):
    common = ['--prompt-tokens', '32', '--chunk-size', '32', '--decode-tokens', '1', '--repeats', '1',
        '--warmups', '0', '--seed', '7', '--timeout-seconds', '170', '--execution-path', 'cbv2-contiguous',
        '--attention-output-precision', 'native', '--ffn-output-precision', 'native', '--ffn-branch-precision', 'native']
    commands = []
    for dtype in ('float32', 'bfloat16'):
        commands.append(dict(name='tiny-' + dtype, command=[str(RUN / 'bundle/cluster-inference'), '--mode',
            'qwen-gdn-arithmetic-check', '--synthetic', '--synthetic-profile', 'tiny', '--synthetic-dtype', dtype,
            '--tokens-file', str(RUN / 'synthetic-prompt-32.json'), *common]))
    interpreter = receipt['planned_commands'][2]['command'][0]
    require(interpreter == '/opt/homebrew/opt/python@3.14/bin/python3.14', 'Launcher interpreter differs')
    commands.append(dict(name='real9b-solo', command=[interpreter, str(RUN / 'source/experiments/cluster/run_inference.py'),
        '--spec', str(RUN / 'real9b-solo.spec.json'), '--bundle', str(RUN / 'bundle'), '--output', str(RUN / 'real9b-solo')]))
    commands.append(dict(name='real9b-gdn', command=[str(RUN / 'bundle/cluster-inference'), '--mode',
        'qwen-gdn-arithmetic-check', '--model-dir', str(MODEL), '--artifact-aggregate-sha256', AGGREGATE,
        '--tokens-file', str(RUN / 'prompt-32.json'), *common]))
    require(receipt['planned_commands'] == commands and receipt['planned_native_calls'] == len(receipt['native_calls']) == 4,
        'Planned argv/call budget differs')
    for command, call in zip(commands, receipt['native_calls']):
        require(call['name'] == command['name'] and call['command'] == command['command'], 'Actual argv differs')
        if call['name'] != 'real9b-solo':
            require(any(shlex.split(process['command']) == command['command'] for process in call['owned_processes']),
                'Native argv not present in saved owned process observations')


def resources(call):
    require(call['status'] == 'validated' and call['exit_code'] == 0 and call['outer_timeout_seconds'] == 195
        and 0 < call['wall_seconds'] < 195, 'Call completion/deadline differs')
    require(call['cleanup'] == dict(all_observed_owned_processes_exited=True, launcher_reaped=True,
        cancel_files_requested=False), 'Saved cleanup incomplete')
    require(call['preflight']['passed'] is True and call['postflight']['passed'] is True, 'Admission/postflight failed')
    samples = call['memory_samples']
    require(samples, 'Missing resource samples')
    states = [call['preflight'], *samples, call['postflight']]
    for state in states:
        require(state['memory_pressure_level'] == 2 and state['severe_pressure'] is False, 'Pressure level changed')
        require(state['required_headroom_bytes'] == 8266034790 and state['diagnostic_extra_reserve_bytes'] == 1024**3
            and state['diagnostic_known_extra_accounting_bytes'] == 666099712, 'Memory estimate policy differs')
        pages = {key: int(value) for key, value in re.findall(r'^([^\n]+?):\s+(\d+)\.$', state['vm_stat'], re.M)}
        reclaimable = sum(pages[key] for key in ('Pages free', 'Pages inactive', 'Pages speculative')) * state['page_size_bytes']
        require(reclaimable == state['estimated_reclaimable_bytes'], 'Reclaimable accounting differs')
        swap = int(float(re.search(r'used = ([0-9.]+)M', state['swap_usage']).group(1)) * 1024**2)
        require(swap == state['swap_used_bytes'], 'Swap accounting differs')
        require(state['memory_passed'] == (reclaimable >= state['required_headroom_bytes']), 'Memory gate bookkeeping differs')
    new_swap = max(state['swap_used_bytes'] for state in states) - states[0]['swap_used_bytes']
    require(new_swap == 0, 'Recorded run has new swap')
    require(call['peak_observed_owned_rss_bytes'] >= max(state['owned_process_rss_bytes'] for state in samples),
        'Peak RSS below sampled RSS')
    return dict(name=call['name'], exit_code=0, saved_cleanup_verified=True, sample_count=len(samples),
        pressure_levels=[2], starting_swap_used_bytes=states[0]['swap_used_bytes'], maximum_new_swap_bytes=new_swap,
        peak_observed_owned_rss_bytes=call['peak_observed_owned_rss_bytes'],
        minimum_sampled_reclaimable_bytes=min(state['estimated_reclaimable_bytes'] for state in samples),
        startup_required_headroom_bytes=states[0]['required_headroom_bytes'],
        samples_below_startup_headroom=sum(not state['memory_passed'] for state in samples),
        live_abort_policy='pressure >=4 or >1GiB new swap; startup headroom is not a live abort threshold')


def main():
    output = RUN / 'independent-cpu-audit.json'
    require(not output.exists(), 'Preserve previous audit')
    receipt = read(RUN / 'receipt.json')
    archived_bindings(receipt)
    check_commands(receipt)
    sys.path[:0] = [str(RUN), str(RUN / 'source/experiments/cluster')]
    driver = load_module('frozen_arithmetic_driver', RUN / 'validate-qwen-gdn-arithmetic.py')
    base = sys.modules['qwen_gdn_input_audit']
    arithmetic = sys.modules['qwen_gdn_arithmetic_audit']
    from runtime.artifacts import verify_files
    from runtime.configuration import validate, rank_configuration
    from runtime.reports import reports
    bundle = read(RUN / 'bundle/bundle.json')
    require(sha(RUN / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest differs')
    for path in [RUN / 'bundle', RUN / 'real9b-solo/bundle']:
        require(verify_files(path, bundle['files']) == receipt['bundle_files'] == receipt['bundle_final_files'],
            'Archived/staged binary or bundle differs')
    prompt, synthetic_prompt = read(RUN / 'prompt-32.json'), read(RUN / 'synthetic-prompt-32.json')
    require(prompt == read(RUN / 'prompt-96.json')[:32] and synthetic_prompt == list(range(3, 35)), 'Prompt differs')
    require(base.digest(base.canonical(read(RUN / 'prompt-96.json'))) == receipt['frozen_96_prompt_sha256'],
        'Original 96-token commitment differs')
    spec = read(RUN / 'real9b-solo.spec.json')
    require(validate(spec) == spec and spec['workload'] == dict(synthetic=False, prompt_ids=prompt,
        prompt_tokens=32, chunk_size=32, decode_tokens=1, repeats=1, warmups=0, seed=7,
        execution_path='cbv2-contiguous', attention_output_precision='native', ffn_output_precision='native',
        ffn_branch_precision='native'), 'Solo workload differs')
    run = read(RUN / 'real9b-solo/run.json')
    require(run['spec'] == spec and run['exit_codes'] == [0] and run['verified_execution'] is True
        and run['hardware_throughput_candidate'] is False and run['cancellation_reason'] is None
        and run['bundle_manifest_sha256'] == receipt['bundle_manifest_sha256'], 'Solo execution differs')
    require(reports(run['ranks'], spec) == run['reports'], 'Solo raw report differs')
    rank = read(RUN / 'real9b-solo/rank-0/rank.json')
    require(rank == rank_configuration(spec, 0, RUN / 'real9b-solo/bundle', receipt['bundle_manifest_sha256'], None)
        and read(RUN / 'real9b-solo/rank-0/prompt.json') == prompt, 'Solo staged native configuration differs')
    solo_report = run['reports'][0]
    solo = driver.one_row(read(RUN / 'real9b-solo/rank-0/logits.json'), 248320)
    require(solo_report['schemaVersion'] == 9 and solo_report['configurationSHA256'] == CONFIG
        and solo_report['runs'][0]['decodeForwardCount'] == 0, 'Solo schema/config/schedule differs')
    native_argv = [str(RUN / 'real9b-solo/bundle/cluster-inference')] + [value.replace('@model', str(MODEL)).replace(
        '@rank', str(RUN / 'real9b-solo/rank-0')) for value in rank['arguments']]
    require(any(shlex.split(process['command']) == native_argv for process in receipt['native_calls'][2]['owned_processes']),
        'Solo native argv differs from staged rank configuration')
    print('Archived source, bundle, four argv and matched solo verified.', flush=True)
    text = read(MODEL / 'config.json')['text_config']
    diagnostics, memory, raw_bindings, artifact_attestations = {}, [], {}, []
    for call in receipt['native_calls']:
        name = call['name']
        memory.append(resources(call))
        for relative, expected in call['evidence_sha256'].items():
            require(sha(RUN / relative) == expected, 'Saved evidence changed: ' + relative)
        for stream in ('stdout', 'stderr'):
            path = RUN / (name + '-launcher') / (stream + '.txt')
            require(sha(path) == call[stream + '_sha256'], 'Launcher output changed')
        require((RUN / (name + '-launcher') / 'stderr.txt').stat().st_size == 0, 'Unexpected launcher stderr')
        require(call['model_before_aggregate_sha256'] == call['model_after_aggregate_sha256'] == AGGREGATE,
            'Driver per-call artifact attestation differs')
        artifact_attestations.append(dict(name=name, before=AGGREGATE, after=AGGREGATE))
        raw_bindings[name] = dict(stdout_sha256=call['stdout_sha256'], stderr_sha256=call['stderr_sha256'])
        if name == 'real9b-solo':
            require(call['result'] == solo_report and sha(RUN / 'real9b-solo/run.json') == call['run_sha256']
                and sha(RUN / 'real9b-solo/rank-0/logits.json') == call['logits_sha256'], 'Solo receipt differs')
            continue
        result = driver.read_diagnostic(RUN / (name + '-launcher') / 'stdout.txt')
        synthetic = name.startswith('tiny-')
        dtype = name.removeprefix('tiny-') if synthetic else 'bfloat16'
        configuration = driver.synthetic_text(dtype) if synthetic else text
        driver.diagnostic_identity(result, synthetic, dtype, synthetic_prompt if synthetic else prompt, None if synthetic else CONFIG)
        computed = arithmetic.arithmetic_oracle(result, configuration)
        require(computed == call['cpu_arithmetic_oracle'] and computed['baseline'] == call['cpu_projection_oracle'],
            'CPU arithmetic replay differs from saved receipt')
        previous = driver.read_diagnostic(PRIOR / (name + '-launcher') / 'stdout.txt')
        for field in ('normalizedInput', 'firstLogits', 'sourceProjections', 'full', 'ranks'):
            require(result[field] == previous[field], 'Native reference changed: ' + field)
        require(call['native_matches_prior'] == dict(all_native_inputs_outputs_exact=True,
            prior_raw_sha256=sha(PRIOR / (name + '-launcher') / 'stdout.txt'), prior_audit_sha256=PRIOR_AUDIT),
            'Prior-reference binding differs')
        diagnostics[name] = dict(native=computed['baseline']['reassembled'],
            float32=computed['float32']['fullVersusRanks']['reassembled'],
            native_cast_float32=computed['float32']['nativeCastFullVersusRanks']['reassembled'],
            padded_native=computed['paddedNative']['nativeFullVersusRanks']['reassembled'],
            float32_departures=computed['float32']['departures'], padded_departures=computed['paddedNative']['departures'],
            normalized_input_sha256=result['normalizedInput']['logicalBytesSHA256'],
            first_logits_sha256=result['firstLogits']['logicalBytesSHA256'], prior_native_reference_exact=True)
        if not synthetic:
            weights = arithmetic.verify_real_arithmetic_weight_bytes(result, MODEL, text)
            require(weights == call['independent_arithmetic_source_byte_checks'] and weights['tensorCheckCount'] == 37,
                '37 actual source/variant identities differ')
            row = base.capture(result['firstLogits'])
            comparison = base.metrics(solo, row)
            require(dict(comparison, prior96_not_used_as_control=True) == receipt['capture_versus_matching_solo']
                and comparison['exact'] and base.logical_bytes(solo, result['firstLogits']['dtype']) ==
                base.logical_bytes(row, result['firstLogits']['dtype']), 'Matched solo logits differ')
            require(solo_report['runs'][0]['generatedTokens'] == [result['firstLogitArgmaxToken']], 'First token differs')
            require(result['verifiedDiagnosticLoad'] == dict(schemaVersion=1, verifiedAggregateSHA256=AGGREGATE,
                configurationSHA256=CONFIG, sourceModelTensorBytes=5038041600, loadedTensorBytes=5038041600,
                largestHostTensorBytes=508559360, tensorCount=927, sourceTensorCount=927,
                parameterLayoutSHA256=solo_report['parameterLayoutSHA256'], bf16ConversionEnabled=True),
                'Verified-loader receipt differs')
            diagnostics[name]['source_byte_checks'] = dict(count=37, identities_sha256=base.digest(base.canonical(weights['tensorChecks'])),
                bytes_checked=sum(item['bytesChecked'] for item in weights['tensorChecks']),
                full_source_byte_check_receipt_key='native_calls[3].independent_arithmetic_source_byte_checks')
            diagnostics[name]['matching_solo_logits'] = dict(comparison, native_dtype_bytes_exact=True,
                first_argmax_token=result['firstLogitArgmaxToken'])
        print(name + ': raw arithmetic, prior native reference and source identities verified.', flush=True)
    require(receipt['model_before_aggregate_sha256'] == receipt['model_final_aggregate_sha256'] == AGGREGATE,
        'Driver initial/final model attestation differs')
    require(sha(RUN / 'receipt.json') == RECEIPT, 'Completed receipt mutated during audit')
    result = dict(schema_version=1, status='passed', cpu_only=True,
        audited_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), audit_script_sha256=sha(__file__),
        original_completed_receipt_sha256=RECEIPT, original_completed_receipt_preserved=True,
        tested_binary_sha256=NATIVE, archived_source_manifest_sha256=receipt['source_manifest_sha256'],
        archived_source_entries_verified=160, archived_bundle_manifest_sha256=receipt['bundle_manifest_sha256'],
        archived_bundle_and_staged_solo_bundle_verified=True, archived_driver_and_helper_hashes=receipt['driver_files_sha256'],
        prior_input_audit_sha256=PRIOR_AUDIT, current_repo_source_or_binary_checked=False,
        native_executions_by_audit=0, audited_native_exit_codes=[0, 0, 0, 0], independently_reconstructed_argv=4,
        saved_cleanup_all_calls_verified=True, current_process_inventory_performed=False,
        model_aggregate_sha256=AGGREGATE, full_model_rehashes_by_audit=0,
        driver_full_model_hash_attestations=dict(initial=AGGREGATE, calls=artifact_attestations, final=AGGREGATE),
        actual_selected_model_tensor_bytes_rechecked=True, raw_launcher_hashes=raw_bindings,
        diagnostics=diagnostics, resources=memory,
        scope=dict(throughput_qualified=False, whole_model_numerical_fix_qualified=False,
            model_quality_qualified=False, physical_two_machine_execution=False, kernel_dispatch_traced=False),
        limitations=['Archived inputs, source and binary are audited; current working code may have advanced.',
            'Padding restores exact first-layer projection values in this fixed workload; no whole-model TP fix is established.',
            'The oracle validates bytes/ownership/casts and metrics; it does not emulate Metal quantized matmul.',
            'The full artifact hash is bound to original driver attestations; this audit rereads only selected source tensors.',
            'Pressure level 2 and preexisting swap are recorded; zero new swap does not mean swap-free operation.',
            'In-flight headroom may fall below the startup estimate without triggering the pressure/new-swap abort policy.',
            'RSS is sampled and memory estimates are not hard peak process caps; cleanup uses saved supervisor observations.'])
    with output.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write('\n')
    print(json.dumps(dict(status='passed', output=str(output), output_sha256=sha(output),
        script_sha256=sha(__file__), source_entries=160, tensor_identities=37,
        real_native_padding=diagnostics['real9b-gdn']['padded_native']), sort_keys=True))


if __name__ == '__main__':
    main()
