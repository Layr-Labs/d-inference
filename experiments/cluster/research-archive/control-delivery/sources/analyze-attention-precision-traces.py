#!/usr/bin/env python3
"""CPU-only comparison of format-2 Float32 attention-output router captures.

Usage: python3 analyze-attention-precision-traces.py OUT
The old analyzer remains unchanged; this adapter validates schema/policy first
and reuses its event coverage, original-byte reconstruction and metric helpers.
"""
import copy
import importlib.util
import json
from pathlib import Path
import sys

HELPER_PATH = Path(__file__).with_name('analyze-qwen-moe-routing.py')
_module_spec = importlib.util.spec_from_file_location('previous_qwen_router_analysis', HELPER_PATH)
helper = importlib.util.module_from_spec(_module_spec)
_module_spec.loader.exec_module(helper)
require = helper.require


def json_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f'Duplicate JSON key: {key}')
        result[key] = value
    return result


def read(path):
    return json.loads(path.read_text(), object_pairs_hook=json_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def validate_precision_trace(trace, report, workload, rank, plan):
    require(type(trace.get('formatVersion')) is int and trace['formatVersion'] == 2,
            'Attention precision captures require trace formatVersion2')
    require(type(report.get('schemaVersion')) is int and report['schemaVersion'] == 5,
            'Attention precision captures require native schemaVersion5')
    require(workload.get('attention_output_precision') == 'float32', 'Expected the explicit Float32 attention-output candidate')
    require(report.get('attentionOutputPrecision') == workload['attention_output_precision'] ==
            trace['identity'].get('attentionOutputPrecision'), 'Trace/report/workload precision policy differs')
    require(report.get('routingTraceEnabled') is True and 'routingReplayEnabled' not in report,
            'Expected observation of original routing, without replay intervention')
    require(report.get('correctnessOnly') is True and report.get('throughputMeasurementValid') is False,
            'Router capture cannot qualify timing')
    # The v2 event schema is unchanged. Only after validating the new version and
    # required policy do we adapt a private copy for the original strict checker.
    # Original trace bytes and original version/identity remain in the evidence.
    compatible = copy.deepcopy(trace)
    compatible['formatVersion'] = 1
    del compatible['identity']['attentionOutputPrecision']
    return helper.validate_trace(compatible, report, workload, rank, plan)


def validate_report(report, workload, rank, plan, instrumented=True):
    world = 1 if plan == 'solo' else 2
    dtype = workload['synthetic_dtype']
    expected = dict(schemaVersion=5, rank=rank, worldSize=world,
        mode='baseline' if plan == 'solo' else 'ffn-tp', partition='none' if plan == 'solo' else 'full',
        transport='none' if plan == 'solo' else 'loopback-test', syntheticWeights=True,
        teacherForced=True, syntheticDType=dtype, syntheticProfile='qwen-moe', feedForwardKind='moe',
        seed=workload['seed'], chunkSize=workload['chunk_size'], vocabularySize=512,
        attentionOutputPrecision='float32', model=f'synthetic-qwen35-w4g64-seed-{workload["seed"]}',
        embeddingActivationDType=dtype, ffnScaleDTypes=[dtype])
    for key, value in expected.items():
        require(type(report.get(key)) is type(value) and report[key] == value, f'Native report {key} differs')
    require('routingReplayEnabled' not in report, 'Routing replay cannot serve as an ordinary reference')
    if instrumented:
        require(report.get('routingTraceEnabled') is True and report.get('correctnessOnly') is True and
                report.get('throughputMeasurementValid') is False, 'Capture does not carry diagnostic flags')
    else:
        require('routingTraceEnabled' not in report, 'Reference unexpectedly has routing instrumentation')
    require(len(report['runs']) == 1, 'Expected exactly one run per controlled history')
    run = report['runs'][0]
    require(run['iteration'] == 0 and run['promptTokens'] == workload['prompt_tokens'] and
            run['decodeForwardCount'] == workload['decode_tokens'] - 1 and
            run['decodeInputTokens'] == workload['teacher_tokens'], 'Actual controlled history differs')


def validate_outputs(logits, report, workload):
    values = helper.matrix(logits, workload['decode_tokens'], 512, 'whole-model logits')
    selected = report['runs'][0]['generatedTokens']
    argmax = [max(range(512), key=row.__getitem__) for row in values]
    require(argmax == report['runs'][0]['localArgmaxTokens'], 'Captured whole logits do not reproduce local argmax')
    require(report['rank'] != 0 or selected == argmax, 'Selecting rank differs from actual argmax')
    require(report['runs'][0]['localArgmaxDisagreementCount'] == sum(a != b for a, b in zip(argmax, selected)),
            'Local argmax disagreement count differs')
    return values


def validate_peers(ranks):
    first, second = ranks
    a, b = first['trace'], second['trace']
    require({k: v for k, v in a['identity'].items() if k != 'rank'} ==
            {k: v for k, v in b['identity'].items() if k != 'rank'}, 'Peer trace identities differ')
    # All event fields are required to agree, including exact original byte
    # hashes, geometry, original values, replay IDs/order/weights and tie labels.
    require(a['events'] == b['events'], 'Peer router events differ')
    for key in ('configurationSHA256', 'parameterLayoutSHA256', 'partitionPlanSHA256',
                'attentionOutputPrecision', 'promptSHA256', 'teacherSHA256'):
        require(first['report'][key] == second['report'][key], f'Peer report {key} differs')
    require(helper.original_bytes(first['logits'], 'float32') == helper.original_bytes(second['logits'], 'float32'),
            'Peer whole-model logits differ')


def load_capture(out, name, receipt):
    plan = 'solo' if name == 'wide-solo' else 'full'
    world = 1 if plan == 'solo' else 2
    directory = out / name
    entries = [entry for entry in receipt['executions'] if entry['name'] == name]
    require(len(entries) == 1, f'Expected one completed {name} capture')
    entry = entries[0]
    require(entry['exit_codes'] == [0] * world and entry['rejected'] is False, 'Capture did not complete successfully')
    run_path = directory / 'run.json'
    require(helper.digest(run_path.read_bytes()) == entry['run_sha256'], 'Capture run receipt hash differs')
    record = read(run_path)
    require(record['name'] == name and record['exit_codes'] == [0] * world, 'Capture rank completion differs')
    require(len(record['reports']) == len(record['ranks']) == world, 'Capture rank count differs')
    manifest = helper.digest((directory / 'bundle/bundle.json').read_bytes())
    require(manifest == entry['bundle_manifest_sha256'] == record['bundle_manifest_sha256'], 'Capture bundle manifest differs')
    require(helper.digest((directory / 'bundle/cluster-inference').read_bytes()) == receipt['binary_sha256'], 'Capture binary differs')
    spec = record['spec']
    workload = spec['workload']
    require(spec['backend'] == ('solo' if plan == 'solo' else 'loopback-test') and
            spec['partition'] == ('ffn' if plan == 'solo' else 'full') and spec['capture_logits'] is True,
            'Unexpected capture backend/partition/outputs')
    require(len(spec['ranks']) == world and all(rank['location'] == 'local' for rank in spec['ranks']),
            'Expected only local capture ranks')
    require(workload['synthetic'] is True and workload['synthetic_profile'] == 'qwen-moe' and
            workload['synthetic_dtype'] in ('float32', 'bfloat16') and workload['attention_output_precision'] == 'float32',
            'Unexpected precision experiment fixture')
    require(workload['repeats'] == 1 and workload['warmups'] == 0 and 0 < workload['prompt_tokens'] <= 512 and
            0 < workload['decode_tokens'] <= 32 and workload['chunk_size'] > 0,
            'Capture workload exceeds bounded one-run diagnostic')
    ranks = []
    for rank, (report, rank_record) in enumerate(zip(record['reports'], record['ranks'])):
        require(rank_record['rank'] == rank, 'Capture rank descriptors are out of order')
        validate_report(report, workload, rank, plan)
        trace_path = directory / f'rank-{rank}/routing.json'
        logits_path = directory / f'rank-{rank}/logits.json'
        require(helper.digest(trace_path.read_bytes()) == rank_record['routing_sha256'], 'Capture trace hash differs')
        require(helper.digest(logits_path.read_bytes()) == rank_record['logits_sha256'], 'Capture output hash differs')
        trace = read(trace_path)
        tokens = validate_precision_trace(trace, report, workload, rank, plan)
        logits = validate_outputs(read(logits_path), report, workload)
        ranks.append(dict(trace=trace, tokens=tokens, logits=logits, report=report))
    if world == 2:
        validate_peers(ranks)
    reference = receipt['uninstrumented_references'][name]
    reference_directory = Path(reference['directory'])
    if not reference_directory.is_absolute():
        reference_directory = out / reference_directory
    reference_run_path = reference_directory / 'run.json'
    require(helper.digest(reference_run_path.read_bytes()) == reference['run_sha256'], 'Uninstrumented reference run hash differs')
    untraced = read(reference_run_path)
    require(untraced['verified_execution'] is True and untraced['exit_codes'] == [0] * world and
            untraced['hardware_throughput_candidate'] is False, 'Uninstrumented reference execution is incomplete or misclassified')
    require(untraced['spec']['workload'] == workload and untraced['spec']['backend'] == spec['backend'] and
            untraced['spec']['partition'] == spec['partition'], 'Uninstrumented reference workload/partition differs')
    require(untraced['bundle_manifest_sha256'] == manifest, 'Uninstrumented reference bundle identity differs')
    require(helper.digest((reference_directory / 'bundle/cluster-inference').read_bytes()) == receipt['binary_sha256'],
            'Uninstrumented reference native binary differs')
    require(len(untraced['reports']) == len(reference['rank_logits_sha256']) == world, 'Uninstrumented reference ranks missing')
    for rank, capture in enumerate(ranks):
        report = untraced['reports'][rank]
        validate_report(report, workload, rank, plan, instrumented=False)
        for key in ('configurationSHA256', 'parameterLayoutSHA256', 'partitionPlanSHA256', 'attentionOutputPrecision',
                    'promptSHA256', 'teacherSHA256', 'tokenSelectionPolicy'):
            require(report.get(key) == capture['report'].get(key), f'Uninstrumented reference {key} differs')
        for key in ('generatedTokens', 'decodeInputTokens', 'localArgmaxTokens'):
            require(report['runs'][0][key] == capture['report']['runs'][0][key], f'Uninstrumented reference {key} differs')
        path = reference_directory / f'rank-{rank}/logits.json'
        require(helper.digest(path.read_bytes()) == reference['rank_logits_sha256'][rank], 'Uninstrumented reference output hash differs')
        values = validate_outputs(read(path), report, workload)
        require(helper.original_bytes(values, 'float32') == helper.original_bytes(capture['logits'], 'float32'),
                'Router capture changed whole-model output relative to the uninstrumented reference')
    return dict(name=name, workload=workload, manifest=manifest, ranks=ranks)


def analyze(out):
    receipt = read(out / 'receipt.json')
    require(receipt['synthetic_only'] is True and receipt['performance_measurements_valid'] is False,
            'Unexpected precision capture scope')
    require(set(receipt['uninstrumented_references']) == {'wide-solo', 'wide-full'}, 'Expected both same-policy reference runs')
    baseline = load_capture(out, 'wide-solo', receipt)
    full = load_capture(out, 'wide-full', receipt)
    require(baseline['manifest'] == full['manifest'], 'Solo/full capture runtime bundles differ')
    require(baseline['workload'] == full['workload'], 'Solo/full precision workload differs')
    for key in ('attentionOutputPrecision', 'configurationSHA256', 'promptSHA256', 'teacherSHA256',
                'decodeInputsSHA256', 'syntheticDType', 'syntheticProfile', 'seed', 'chunkSize', 'promptTokens', 'decodeTokens'):
        require(baseline['ranks'][0]['trace']['identity'][key] == full['ranks'][0]['trace']['identity'][key],
                f'Solo/full trace identity {key} differs')
    comparison = helper.compare_execution(baseline, full)
    comparison['attention_output_precision'] = 'float32'
    comparison['same_numerical_policy'] = True
    comparison['untraced_control_exact_logits_validated'] = True
    return dict(schema_version=1, kind='attention_output_precision_router_analysis',
        structural_validation_passed=True, synthetic_only=True, performance_measurements_valid=False,
        quality_qualification='Diagnostic-only; this does not qualify BF16 correctness or relax any numerical bound.',
        attention_output_precision='float32', source_trace_format=2, source_report_schema=5,
        routing_scope='Original model routing; top-k IDs and weights are exact stock public-MLX replay of actual captured logits.',
        byte_checks='Original F32/BF16 bytes reconstructed from JSON and compared with captured SHA256; complete peer events and final outputs agree.',
        control_checks='All three captured rank outputs exactly equal the identity-bound uninstrumented reference outputs.',
        causality_limit='This correlates router input/logit rounding, route changes and whole-logit differences; it does not isolate every cause.',
        output_coordinates='Row0 follows the final prompt token; rowN>0 follows teacher[N-1]. Consumed-token positions are zero-based.',
        ignored_execution_names=[x['name'] for x in receipt['executions'] if x['name'] not in ('wide-solo', 'wide-full')],
        binary_sha256=receipt['binary_sha256'], analyzer_sha256=helper.digest(Path(__file__).read_bytes()),
        reused_helper_sha256=helper.digest(HELPER_PATH.read_bytes()), source_receipt_sha256=helper.digest((out/'receipt.json').read_bytes()),
        comparison=comparison)


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: analyze-attention-precision-traces.py OUT')
    out = Path(sys.argv[1]).resolve()
    try:
        result = analyze(out)
    except (ValueError, KeyError, TypeError, IndexError, OSError, OverflowError) as exc:
        result = dict(kind='attention_output_precision_router_analysis', structural_validation_passed=False,
                      performance_measurements_valid=False, error=f'{type(exc).__name__}: {exc}')
        (out / 'analysis.json').write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
        raise SystemExit(result['error'])
    (out / 'analysis.json').write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
    comparison = result['comparison']
    count = sum(x['changed_expert_sets'] for x in comparison['layer_summaries'])
    orders = sum(x['order_only_changes'] for x in comparison['layer_summaries'])
    first = comparison['first_changed_expert_set']
    where = 'none' if first is None else f'layer{first["layer"]}/token{first["processed_token_index"]}'
    print(f'Float32 attention-output policy: expert_set_changes={count}, order_only={orders}, first={where}, '
          f'peak_row={comparison["peak_output_row"]}, max_row_RMS={comparison["maximum_output_relative_rms"]:.9g}, '
          f'max_abs={comparison["maximum_output_absolute_error"]:.9g}, '
          f'argmax={comparison["argmax_agreements"]}/{len(comparison["output_rows"])}')
    print('Identity, byte reconstruction, exact peer and uninstrumented-control checks passed. No BF16 quality qualification.')
    print(out / 'analysis.json')


if __name__ == '__main__':
    main()
