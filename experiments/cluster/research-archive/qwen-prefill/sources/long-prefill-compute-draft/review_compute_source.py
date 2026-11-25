"""CPU metadata/source review; never imports MLX or starts native processes."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

PINS = {
    'reference': '55793df7791aa60ed79ac6d6a7d9b5f1eb18283514a0b5be6d9593846511b78c',
    'wire': '36af6ffa2b0c21ca45968d5f7131fa73617e6ab52866a87caad95a4eda6a671d',
    'geometry': '8ca2a1d13792501ba13f37322766e30fd232a59e373883dc0c36bd010ddf7ca3',
    'configuration': 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423',
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def metadata(path):
    data = path.read_bytes()
    return dict(path=path.name, sha256=sha(data), size_bytes=len(data))


def state_oracle(configuration):
    raw = configuration.read_bytes()
    assert sha(raw) == PINS['configuration']
    text = json.loads(raw)['text_config']
    assert text['num_hidden_layers'] == 32 and text['full_attention_interval'] == 4
    channels = 2 * text['linear_num_key_heads'] * text['linear_key_head_dim'] + text['linear_num_value_heads'] * text['linear_value_head_dim']
    conv = 2 * (text['linear_conv_kernel_dim'] - 1) * channels
    ssm = 4 * text['linear_num_value_heads'] * text['linear_value_head_dim'] * text['linear_key_head_dim']
    one_kv = 2 * 8192 * text['num_key_value_heads'] * text['head_dim']
    stage = 12 * (conv + ssm) + 4 * (2 * one_kv + 4)
    assert 12 * 2 + 4 * 3 == 36
    assert stage == 159_973_392 and 2 * stage == 319_946_784
    assert 512 * text['hidden_size'] * 2 == 4_194_304 <= 16 * 1024**2
    assert text['vocab_size'] * 2 == 496_640
    return dict(configuration_sha256=sha(raw), state_entries_per_stage=36,
        logical_state_bytes_per_stage=stage, merged_logical_state_bytes=2 * stage,
        conv_component_bytes=conv, ssm_component_bytes=ssm, one_kv_component_bytes=one_kv,
        one_native_boundary_bytes=4_194_304, final_native_logit_bytes=496_640,
        metadata_only=True, native_arrays_observed=False, whole_process_memory_bound=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration-metadata', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    for name in ('reference', 'wire', 'geometry'):
        parser.add_argument('--' + name + '-manifest', type=Path, required=True)
    args = parser.parse_args()
    folder = Path(__file__).resolve().parent
    for name in ('reference', 'wire', 'geometry'):
        assert sha(getattr(args, name + '_manifest').read_bytes()) == PINS[name]
    swift = sorted(folder.glob('*.swift'))
    assert len(swift) == 6
    for path in swift:
        text = path.read_text()
        assert len(text.splitlines()) <= 220
        assert all(term not in text for term in ('/Users/', 'ProcessInfo.processInfo', 'getenv(',
            'Process()', '.asType(', 'model.update(', 'quantize(', 'loadVerifiedQwen'))
    ast.parse(Path(__file__).read_text(), filename=Path(__file__).name)
    source_names = ['QwenLayerStageSession.swift', 'QwenLayerStageBoundary.swift',
        'QwenLayerStageLoadReceipt.swift', 'QwenLayerStagePrefillComputeContext.swift',
        'QwenLayerStagePrefillComputeTypes.swift', 'QwenLayerStageRecordedEvidence.swift',
        'CBv2OwnedStateSnapshot.swift', 'CBv2OwnedRequestState.swift',
        'QwenRegistered9BLongPrefillAdmission.swift', 'QwenLongPrefillArithmeticEnvironment.swift']
    record = dict(kind='long_prefill_compute_source_review', schema_version=1, date='2026-09-14',
        passed=True, status='frozen_source_only',
        files=[metadata(p) for p in sorted(folder.iterdir()) if p.suffix in ('.swift', '.py', '.md')],
        dependency_manifest_sha256=PINS, source_dependencies=[metadata(args.source / n) for n in source_names],
        state_metadata_oracle=state_oracle(args.configuration_metadata),
        new_swift_files=6, swift_compiled=False, native_executed=False, gpu_executed=False,
        ssh_performed=False, model_payload_read=False, repository_sources_edited=False,
        existing_v3_files_edited=False, transport_implemented=False, reference_parser_implemented=False,
        reference_comparison_performed=False, performance_measurement_performed=False,
        read_only_reviews=[
            'Root reviewed six core files: no blocker reported.',
            'pipeline_stage_plan reviewed six files against Session/Boundary/types: no concrete API or lifetime blocker.'],
        entry='QwenLayerStageProfiledPrefillComputeContext(loaded:local:agreement:check:)',
        limitations=['Source and metadata review does not establish compilation, model parity or lifecycle execution.',
            'Whole-cohort ownership, post-stop ordering, reference admission and native fault validation remain external.'])
    output = folder / 'source-review-20260914.json'
    with output.open('x') as stream:
        json.dump(record, stream, sort_keys=True, indent=2); stream.write('\n')
    print(json.dumps(dict(passed=True, manifest=output.name, sha256=sha(output.read_bytes()),
        swift_files=6, stage_logical_state_bytes=159_973_392, swift_compiled=False, native_executed=False), sort_keys=True))


if __name__ == '__main__':
    main()
