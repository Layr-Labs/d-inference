#!/usr/bin/env python3
"""CPU metadata/raw-logit audit of the completed tiny stage run; no model IO."""
import datetime
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
RUN = ROOT / 'runs/qwen-layer-stage-runtime-20260913'
NATIVE = '1e249820b3f5bdddbdf5835d3201935de0ee93a30711cfb8321875d01c2196e9'
RECEIPT = '4ad34491060a9a7730ad6df71f1ec504b7745577f4ee8e118d5dcc0efdd9bcda'
BASE_ORACLE = ROOT / 'runs/qwen-gdn-input-20260913/qwen_gdn_input_audit.py'
BASE_ORACLE_SHA = '8ce87bd399ec523bacf69cbd01dd15d0f0eab0d6b684aa2afc0e34d5eb984e1e'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for part in iter(lambda: stream.read(4 * 1024**2), b''):
            h.update(part)
    return h.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False, ensure_ascii=False).encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def read(path):
    return parse(Path(path).read_text())


def parse(raw):
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON identity')
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique,
        parse_int=lambda value: -0.0 if value == '-0' else int(value),
        parse_constant=lambda value: require(False, 'Nonfinite JSON'))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    sys.modules[name] = value
    spec.loader.exec_module(value)
    return value


def source_config(dtype, wrapped):
    text = dict(model_type='qwen3_5_text', hidden_size=128, num_hidden_layers=8, intermediate_size=256,
        num_attention_heads=4, num_key_value_heads=2, head_dim=64, linear_num_key_heads=2,
        linear_num_value_heads=2, linear_key_head_dim=128, linear_value_head_dim=128,
        linear_conv_kernel_dim=4, full_attention_interval=4, vocab_size=512, tie_word_embeddings=False,
        max_position_embeddings=8192, mtp_num_hidden_layers=0, cluster_fixture_dtype=dtype,
        layer_types=['full_attention' if (i + 1) % 4 == 0 else 'linear_attention' for i in range(8)])
    policy = dict(bits=4, group_size=64, mode='affine')
    return dict(model_type='qwen3_5', text_config=text, quantization=policy) if wrapped else dict(text, quantization=policy)


def expected_parameters(dtype, wrapped, fp16):
    """Explicit tiny constructor geometry; no native mapping or descriptor helper."""
    prefix = 'language_model.' if wrapped else ''
    result = {}
    def add(name, shape, dt):
        source_dtype = 'float16' if fp16 and '.layers.' in name and name.endswith(('.scales', '.biases')) else dt
        result[name] = dict(shape=shape, sourceDType=source_dtype, loadedDType=dt,
            byteCount=math.prod(shape) * (4 if dt in ('uint32', 'float32') else 2))
    def affine(path, rows, inputs):
        add(path + '.weight', [rows, inputs // 8], 'uint32')
        for suffix in ('scales', 'biases'):
            add(path + '.' + suffix, [rows, inputs // 64], dtype)
    affine(prefix + 'model.embed_tokens', 512, 128)
    affine(prefix + 'lm_head', 512, 128)
    add(prefix + 'model.norm.weight', [128], dtype)
    for layer in range(8):
        p = prefix + f'model.layers.{layer}.'
        for norm in ('input_layernorm', 'post_attention_layernorm'):
            add(p + norm + '.weight', [128], dtype)
        for projection in ('gate_proj', 'up_proj'):
            affine(p + 'mlp.' + projection, 256, 128)
        affine(p + 'mlp.down_proj', 128, 256)
        if (layer + 1) % 4 == 0:
            for projection, rows in [('q_proj', 512), ('k_proj', 128), ('v_proj', 128)]:
                affine(p + 'self_attn.' + projection, rows, 128)
            affine(p + 'self_attn.o_proj', 128, 256)
            for norm in ('q_norm', 'k_norm'):
                add(p + 'self_attn.' + norm + '.weight', [64], dtype)
        else:
            for projection, rows in [('in_proj_qkv', 768), ('in_proj_z', 256), ('in_proj_b', 2), ('in_proj_a', 2)]:
                affine(p + 'linear_attn.' + projection, rows, 128)
            affine(p + 'linear_attn.out_proj', 128, 256)
            add(p + 'linear_attn.conv1d.weight', [768, 4, 1], dtype)
            add(p + 'linear_attn.norm.weight', [128], dtype)
            for parameter in ('A_log', 'dt_bias'):
                add(p + 'linear_attn.' + parameter, [2], dtype)
    require(len(result) == 237, 'Independent fixture inventory count differs')
    return result


def local_names(parameters, wrapped, index):
    prefix = 'language_model.' if wrapped else ''
    result = []
    for name, tensor in parameters.items():
        match = re.fullmatch(re.escape(prefix) + r'model\.layers\.(\d+)\.(.+)', name)
        if match:
            layer = int(match[1])
            if layer // 4 != index:
                continue
            local = prefix + f'model.layers.{layer % 4}.' + match[2]
        else:
            owner = 0 if name.startswith(prefix + 'model.embed_tokens.') else 1
            if owner != index:
                continue
            local = name
        result.append(dict(sourceName=name, localName=local, **tensor))
    return sorted(result, key=lambda value: value['localName'])


def layout(entries, key='localName'):
    return digest('\n'.join(sorted(f"{item[key]}:{item['loadedDType']}:{item['shape']}" for item in entries)).encode())


def fixture_metadata(loader, parity, dtype, wrapped, fp16, raw):
    parameters = expected_parameters(dtype, wrapped, fp16)
    configuration = source_config(dtype, wrapped)
    configuration_sha = digest(canonical(configuration))
    require(parity['sourceConfigurationSHA256'] == configuration_sha, 'Independent source configuration differs')
    source_bytes = sum(value['byteCount'] for value in parameters.values())
    require(loader['sourceTensorBytes'] == source_bytes, 'Independent source tensor bytes differ')
    source_layout = layout([dict(sourceName=name, **value) for name, value in parameters.items()], key='sourceName')
    source_names, active_bytes, inert_bytes = [], [], []
    for index, receipt in enumerate(loader['receipts']):
        expected = local_names(parameters, wrapped, index)
        require(receipt['activeTensors'] == expected, 'Active source/local descriptor mapping differs')
        require(receipt['sourceParameterLayoutSHA256'] == source_layout
            and receipt['activeParameterLayoutSHA256'] == layout(expected)
            and receipt['activeMappingSHA256'] == digest(canonical(expected)), 'Descriptor/layout commitment differs')
        active = sum(value['byteCount'] for value in expected)
        prefix = 'language_model.' if wrapped else ''
        inert = [(prefix + 'model.norm', [128], 'parameter-only-replacement'),
            (prefix + 'lm_head', [1, 128], 'module-replacement')] if index == 0 else [
            (prefix + 'model.embed_tokens', [1, 128], 'module-replacement')]
        inert_by_path = {value['path']: value for value in receipt['inertModules']}
        require(set(inert_by_path) == {value[0] for value in inert}, 'Inactive module inventory differs')
        inert_count = 0
        for path, shape, kind in inert:
            count = math.prod(shape) * (4 if dtype == 'float32' else 2)
            require(inert_by_path[path]['replacementKind'] == kind and inert_by_path[path]['parameters'] == [
                dict(localName=path + '.weight', shape=shape, dtype=dtype, byteCount=count)], 'Inactive descriptor differs')
            inert_count += count
        require(receipt['loadedTensorBytes'] == active and receipt['inertTensorBytes'] == inert_count
            and receipt['largestHostTensorBytes'] == max(value['byteCount'] for value in expected), 'Stage accounting differs')
        require(receipt['storageCommitmentSHA256'] == digest(canonical(receipt['storageCommitment'])), 'Common storage hash differs')
        commitment = receipt['storageCommitment']
        require(commitment['sourceModelTensorBytes'] == source_bytes
            and commitment['canonicalTensorCount'] == commitment['sourceTensorCount'] == 237
            and commitment['largestSourceTensorBytes'] == max(value['byteCount'] for value in parameters.values()),
            'Source commitment accounting differs')
        source_names.extend(value['sourceName'] for value in expected)
        active_bytes.append(active)
        inert_bytes.append(inert_count)
    require(len(source_names) == len(set(source_names)) == 237 and set(source_names) == set(parameters), 'Incomplete ownership')
    require(loader['activeTensorBytes'] == active_bytes and loader['inertTensorBytes'] == inert_bytes
        and sum(active_bytes) == source_bytes, 'Active/inert/source array accounting differs')
    logit_rows = []
    for frame in parity['frames']:
        t = frame['committedTokens']
        width = 4 if dtype == 'float32' else 2
        expected_state = 6 * (1 * 3 * 768 * width + 1 * 2 * 128 * 128 * 4) + 2 * (2 * 1 * 2 * t * 64 * width + 4)
        require(frame['stateBytesCompared'] == expected_state and frame['stateEntriesCompared'] == 18,
            'Independent complete state geometry/byte accounting differs')
        if frame.get('logits') is not None:
            values = raw.capture(frame['logits'])
            require(frame['logits']['shape'] == [1, 512] and frame['logits']['dtype'] == dtype, 'Logit capture geometry differs')
            logit_rows.append(dict(committed_tokens=t, values=512, dtype=dtype,
                logical_bytes_sha256=frame['logits']['logicalBytesSHA256'], argmax_token=values.index(max(values))))
    return dict(dtype=dtype, wrapped=wrapped, fp16_layer_metadata=fp16, source_configuration_sha256=configuration_sha,
        independently_derived_active_descriptors=237, active_tensor_bytes=active_bytes,
        inert_tensor_bytes=inert_bytes, source_tensor_bytes=source_bytes, independently_derived_state_entries_per_frame=18,
        independently_verified_candidate_logit_rows=logit_rows,
        native_pair_equality_assertions=dict(exact_state_frames=6, exact_state_entries=108, exact_logit_rows=4))


def main():
    output = RUN / 'independent-cpu-audit.json'
    require(not output.exists(), 'Preserve existing audit')
    receipt = read(RUN / 'receipt.json')
    require(sha(RUN / 'receipt.json') == RECEIPT and receipt['status'] == 'completed'
        and receipt['expected_native_sha256'] == NATIVE and len(receipt['native_calls']) == 1, 'Completion identity differs')
    for name, expected in receipt['driver_files_sha256'].items():
        require(sha(RUN / name) == expected, 'Archived helper changed')
    require(sha(RUN / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest changed')
    source = read(RUN / 'source-manifest.json')
    require(len(source) == len({item['path'] for item in source}) == 182, 'Source inventory differs')
    for item in source:
        path = RUN / 'source' / item['path']
        require(path.stat().st_size == item['size_bytes'] and sha(path) == item['sha256'], 'Archived source changed')
    bundle = read(RUN / 'bundle/bundle.json')
    require(sha(RUN / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest changed')
    for item in bundle['files']:
        path = RUN / 'bundle' / item['path']
        require(path.stat().st_size == item['size_bytes'] and sha(path) == item['sha256']
            == receipt['bundle_files'][item['path']], 'Archived executable/bundle changed')
    require(receipt['bundle_files']['cluster-inference'] == NATIVE, 'Archived binary differs')
    call = receipt['native_calls'][0]
    expected_argv = [str(RUN / 'bundle/cluster-inference'), '--mode', 'qwen-layer-stage-check', '--synthetic',
        '--execution-path', 'cbv2-contiguous', '--prompt-tokens', '65', '--chunk-size', '32', '--decode-tokens', '4',
        '--repeats', '1', '--warmups', '0', '--timeout-seconds', '170']
    require(call['command'] == expected_argv and call['exit_code'] == 0 and call['outer_timeout_seconds'] == 195
        and 0 < call['wall_seconds'] < 195 and call['cleanup'] == dict(all_observed_owned_processes_exited=True,
            launcher_reaped=True, cancel_files_requested=False), 'Native completion/argv/cleanup differs')
    require(sha(RUN / 'native/stdout.txt') == call['stdout_sha256'] == receipt['native_records_sha256']
        and sha(RUN / 'native/stderr.txt') == call['stderr_sha256'], 'Native output changed')
    stderr = (RUN / 'native/stderr.txt').read_text()
    require(re.fullmatch(r'\[bf16\] converted 124 params \(0\.1 MB\) fp16→bf16 in \d+ ms\n', stderr), 'Unexpected native stderr')
    sys.path.insert(0, str(RUN))
    driver = module('archived_stage_driver', RUN / 'validate-qwen-layer-stage.py')
    rows = [parse(line) for line in (RUN / 'native/stdout.txt').read_text().splitlines() if line.startswith('{')]
    require(driver.check_records(rows) == receipt['fixtures'], 'Native record validation differs')
    require(sha(BASE_ORACLE) == BASE_ORACLE_SHA, 'Raw floating-byte helper changed')
    raw = module('frozen_raw_byte_oracle', BASE_ORACLE)
    fixtures = [fixture_metadata(rows[i * 2], rows[i * 2 + 1], dtype, wrapped, fp16, raw)
        for i, (dtype, wrapped, fp16) in enumerate([('float32', False, False), ('bfloat16', True, False), ('bfloat16', True, True)])]
    states = [call['preflight'], *call['memory_samples'], call['postflight']]
    require(call['preflight']['passed'] is True and call['postflight']['passed'] is True, 'Startup/postflight resources failed')
    for state in states:
        require(state['memory_pressure_level'] == 2 and state['severe_pressure'] is False, 'Pressure changed')
        require(state['swap_used_bytes'] == states[0]['swap_used_bytes'], 'New swap observed')
    require(call['peak_observed_owned_rss_bytes'] >= max(item['owned_process_rss_bytes'] for item in call['memory_samples']),
        'Peak RSS below recorded samples')
    require(sha(RUN / 'receipt.json') == RECEIPT, 'Original completion receipt mutated')
    result = dict(schema_version=1, status='passed', audit_kind='source_bound_metadata_and_raw_candidate_logit_audit',
        cpu_only=True, audited_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), audit_script_sha256=sha(__file__),
        original_completed_receipt_sha256=RECEIPT, tested_binary_sha256=NATIVE,
        archived_source_manifest_sha256=receipt['source_manifest_sha256'], archived_source_entries_verified=182,
        archived_bundle_manifest_sha256=receipt['bundle_manifest_sha256'], archived_bundle_verified=True,
        native_records_sha256=receipt['native_records_sha256'], native_stderr_sha256=call['stderr_sha256'],
        helper_sha256=BASE_ORACLE_SHA, independent_argv_checked=True, native_exit_code=0,
        saved_process_cleanup_verified=True, fixtures=fixtures,
        resources=dict(pressure_levels=[2], new_swap_bytes=0, starting_swap_bytes=states[0]['swap_used_bytes'],
            peak_observed_owned_rss_bytes=call['peak_observed_owned_rss_bytes'], sample_count=len(call['memory_samples']),
            whole_process_peak_not_proven=True), native_executions_by_audit=0, model_payload_reads_by_audit=0,
        scope=dict(real_model_qualified=False, throughput_qualified=False, physical_two_machine_execution=False,
            source_tensor_values_rechecked_by_cpu=False, paired_state_bytes_rechecked_by_cpu=False,
            paired_logit_values_rechecked_by_cpu=False, candidate_logit_logical_hashes_rechecked_by_cpu=True),
        source_review_conclusion='No obvious oracle error found: native code compares every active source tensor before forward and all remapped committed state entries/logit rows during forwarding.',
        limitations=['Fixture tensor values and baseline/candidate state/logit pairs are compared within native code; the raw paired arrays are not persisted.',
            'This audit independently derives tensor/state geometry and accounting and verifies emitted candidate logits/hashes; it cannot replay absent paired arrays.',
            'Full-state hashes are opaque native commitments because individual state entries are not emitted.',
            'Intermediate evaluation-only output values are not compared; only their shape/dtype, committed state, and later complete output rows are checked.',
            'The fixtures and correctness work share one process and run sequentially; there is no model performance or network qualification.'])
    with output.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write('\n')
    print(json.dumps(dict(status='passed', output=str(output), output_sha256=sha(output), script_sha256=sha(__file__),
        fixtures=3, active_descriptors=711, state_frames=18, candidate_logit_rows=12, native_executions=0), sort_keys=True))


if __name__ == '__main__':
    main()
