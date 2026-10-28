#!/usr/bin/env python3
"""CPU-only validation/comparison of the bounded six-run Qwen MoE trace capture.

Usage: python3 analyze-qwen-moe-routing.py OUT
Writes OUT/analysis.json. Structural/identity/peer disagreement is fatal; numerical
baseline differences are diagnostics and are never called a quality pass.
"""
import hashlib
import json
import math
from pathlib import Path
import struct
import sys

DTYPES = ('float32', 'bfloat16')
PLANS = ('solo', 'ffn', 'full')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_digest(value):
    return digest(json.dumps(value, separators=(',', ':'), allow_nan=False).encode())


def read(path):
    return json.loads(path.read_text(), parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def f32(value):
    require(type(value) in (int, float) and math.isfinite(value), 'Nonfinite/non-numeric captured value')
    return struct.unpack('<f', struct.pack('<f', value))[0]


def matrix(value, rows, columns, label):
    require(isinstance(value, list) and len(value) == rows, f'{label}: wrong row count')
    require(all(isinstance(row, list) and len(row) == columns for row in value), f'{label}: wrong width')
    return [[f32(x) for x in row] for row in value]


def original_bytes(rows, dtype):
    require(dtype in DTYPES, f'Unexpected dtype {dtype}')
    output = bytearray()
    for row in rows:
        for value in row:
            raw = struct.pack('<f', f32(value))
            if dtype == 'bfloat16':
                require(raw[:2] == b'\0\0', 'BF16 trace value is not exactly representable')
                raw = raw[2:]
            output.extend(raw)
    return bytes(output)


def error(a, b):
    require(len(a) == len(b) and len(a) > 0, 'Error metric shape mismatch')
    a, b = list(map(f32, a)), list(map(f32, b))
    differences = [x - y for x, y in zip(a, b)]
    energy = math.fsum(x * x for x in a)
    squared = math.fsum(x * x for x in differences)
    worst = max(range(len(a)), key=lambda i: abs(differences[i]))
    return dict(values=len(a), maximum_absolute_error=abs(differences[worst]),
                absolute_rms=math.sqrt(squared / len(a)), reference_rms=math.sqrt(energy / len(a)),
                relative_rms=math.sqrt(squared / max(energy, 1e-30)),
                reference_peak=max(map(abs, a)), maximum_error_index=worst,
                reference_at_maximum_error=a[worst], candidate_at_maximum_error=b[worst])


def expected_calls(prompt, chunk, teacher_count):
    # Qwen prepare processes full chunks while leaving >=1 token for the
    # final model call. A divisible prompt therefore retains one whole chunk.
    widths = []
    remaining = prompt
    while remaining > chunk:
        widths.append(chunk)
        remaining -= chunk
    return widths + [remaining] + [1] * teacher_count


def validate_trace(trace, report, workload, rank, plan):
    expected = dict(formatVersion=1, kind='qwen_moe_router_trace', hiddenSize=128,
                    numExperts=16, topK=4, normalizeTopKProbabilities=True,
                    correctnessOnly=True, timingsAndMemoryInvalidatedByCapture=True)
    for key, value in expected.items():
        require(trace.get(key) == value, f'Trace {key} mismatch')
    require('private IDs not intercepted' in trace['routingMethod'], 'Missing replay limitation')
    require(len(report['runs']) == 1, 'Expected one measured diagnostic execution')
    run = report['runs'][0]
    teacher = workload['teacher_tokens']
    prompt_count, chunk = workload['prompt_tokens'], workload['chunk_size']
    require(run['iteration'] == 0 and run['decodeInputTokens'] == teacher, 'Actual teacher history differs')
    require(run['promptTokens'] == prompt_count and run['decodeForwardCount'] == len(teacher), 'Actual token counts differ')
    require(len(teacher) + 1 == workload['decode_tokens'], 'Teacher/output count mismatch')
    vocabulary = report['vocabularySize']
    prompt = workload.get('prompt_ids')
    if prompt is None:
        prompt = [3 + ((i * 17 + workload['seed'] % (vocabulary - 3)) % (vocabulary - 3)) for i in range(prompt_count)]
    require(len(prompt) == prompt_count, 'Prompt count mismatch')
    expected_identity = dict(configurationSHA256=report['configurationSHA256'], promptSHA256=json_digest(prompt),
        teacherSHA256=json_digest(teacher), decodeInputsSHA256=json_digest(run['decodeInputTokens']),
        generatedTokensSHA256=json_digest(run['generatedTokens']), rank=str(rank),
        worldSize='1' if plan == 'solo' else '2', partition='none' if plan == 'solo' else plan,
        partitionPlanSHA256=report.get('partitionPlanSHA256', 'none'), syntheticDType=workload['synthetic_dtype'],
        syntheticProfile='qwen-moe', seed=str(workload['seed']), chunkSize=str(chunk),
        promptTokens=str(prompt_count), decodeTokens=str(workload['decode_tokens']))
    require(trace['identity'] == expected_identity, 'Trace identity differs from actual report/workload')
    require(report['promptSHA256'] == json_digest(prompt) and report['teacherSHA256'] == json_digest(teacher), 'Report token hashes differ')
    widths = expected_calls(prompt_count, chunk, len(teacher))
    require(trace['callsPerLayer'] == len(widths) and trace['tokensPerLayer'] == prompt_count + len(teacher), 'Trace coverage differs')
    require(len(trace['events']) == 4 * len(widths), 'Missing router events')
    tokens, starts, paths = {}, [0] * 4, {}
    for sequence, event in enumerate(trace['events']):
        call, layer = divmod(sequence, 4)
        rows = widths[call]
        require((event['sequence'], event['call'], event['layer'], event['rows']) == (sequence, call, layer, rows), 'Router event order differs')
        require(event['processedTokenStart'] == starts[layer], 'Router processed-token coordinate differs')
        require(event['path'].endswith(f'.layers.{layer}.mlp'), 'Unexpected router path')
        require(paths.setdefault(layer, event['path']) == event['path'], 'Router path changed between calls')
        require(event['inputShape'] == [1, rows, 128] and event['logitShape'] == [1, rows, 16], 'Router shape mismatch')
        dtype = workload['synthetic_dtype']
        for field in ('inputDType', 'logitDType', 'probabilityDType', 'routingWeightDType'):
            require(event[field] == dtype, f'Unexpected router {field}')
        for field, width in [('inputs', 128), ('logits', 16), ('probabilities', 16), ('selectedExpertWeights', 4), ('probabilityCutoff', 2)]:
            event[field] = matrix(event[field], rows, width, field)
        for field, hash_key in [('inputs', 'inputSHA256'), ('logits', 'logitSHA256')]:
            require(digest(original_bytes(event[field], dtype)) == event[hash_key], f'{field} JSON does not reconstruct original byte hash')
        ids = event['selectedExpertIDs']
        require(len(ids) == rows and all(len(row) == 4 and len(set(row)) == 4 and
                all(type(x) is int and 0 <= x < 16 for x in row) for row in ids), 'Invalid global expert IDs')
        probability_ties, logit_ties = [], []
        for row in range(rows):
            probabilities = event['probabilities'][row]
            ordered = sorted(probabilities, reverse=True)
            raw_ordered = sorted(event['logits'][row], reverse=True)
            require(event['probabilityCutoff'][row] == [ordered[3], ordered[4]], 'Cutoff detail differs')
            selected = set(ids[row])
            require(min(probabilities[i] for i in selected) >= max(probabilities[i] for i in range(16) if i not in selected), 'Replayed IDs are not a valid top4 set')
            if ordered[3] == ordered[4]: probability_ties.append(row)
            if raw_ordered[3] == raw_ordered[4]: logit_ties.append(row)
            key = (layer, starts[layer] + row)
            require(key not in tokens, 'Duplicate layer/token')
            tokens[key] = dict(event=event, row=row)
        require(event['probabilityBoundaryTieTokens'] == probability_ties and event['logitBoundaryTieTokens'] == logit_ties, 'Tie labels differ from captured values')
        starts[layer] += rows
    require(starts == [prompt_count + len(teacher)] * 4, 'Missing layer/token coverage')
    return tokens


def load_execution(out, name, receipt):
    dtype, plan = name.split('-', 1)
    directory = out / name
    record = read(directory / 'run.json')
    spec, reports, ranks = record['spec'], record['reports'], record['ranks']
    world = 1 if plan == 'solo' else 2
    require(record.get('diagnostic_execution_verified') is True and record['exit_codes'] == [0] * world, f'{name}: incomplete execution')
    require(len(reports) == len(ranks) == world and record['name'] == name, f'{name}: rank count/name differs')
    expected_receipt = next(item for item in receipt['executions'] if item['name'] == name)
    require(expected_receipt['diagnostic_execution_verified'] is True and expected_receipt['exit_codes'] == record['exit_codes'], 'Run/receipt completion differs')
    require(digest((directory / 'bundle/bundle.json').read_bytes()) == record['bundle_manifest_sha256'] == expected_receipt['bundle_manifest_sha256'], 'Bundle manifest identity differs')
    require(digest((directory / 'bundle/cluster-inference').read_bytes()) == receipt['binary_sha256'], 'Captured native binary differs')
    workload = spec['workload']
    require(workload['synthetic'] is True and workload['synthetic_profile'] == 'qwen-moe' and workload['synthetic_dtype'] == dtype, 'Unexpected model fixture')
    require(workload['warmups'] == 0 and workload['repeats'] == 1 and 0 < workload['prompt_tokens'] <= 512 and 0 < workload['decode_tokens'] <= 32, 'Workload outside capture bounds')
    require(spec['backend'] == ('solo' if plan == 'solo' else 'loopback-test') and spec['partition'] == ('ffn' if plan == 'solo' else plan), 'Requested partition/backend differs')
    loaded = []
    for rank, (report, rank_record) in enumerate(zip(reports, ranks)):
        expected = dict(rank=rank, worldSize=world, mode='baseline' if plan == 'solo' else 'ffn-tp',
            partition='none' if plan == 'solo' else plan, transport='none' if plan == 'solo' else 'loopback-test',
            routingTraceEnabled=True, correctnessOnly=True, throughputMeasurementValid=False, syntheticWeights=True,
            teacherForced=True, syntheticDType=dtype, syntheticProfile='qwen-moe', feedForwardKind='moe',
            seed=workload['seed'], chunkSize=workload['chunk_size'], vocabularySize=512,
            model=f'synthetic-qwen35-w4g64-seed-{workload["seed"]}', embeddingActivationDType=dtype, ffnScaleDTypes=[dtype])
        for key, value in expected.items(): require(report.get(key) == value, f'{name}/rank{rank}: report {key} differs')
        files = {}
        for filename in ('routing.json', 'logits.json'):
            path = directory / f'rank-{rank}' / filename
            require(digest(path.read_bytes()) == rank_record[filename + '_sha256'], f'{name}/rank{rank}: captured {filename} digest differs')
            files[filename] = read(path)
        trace = files['routing.json']
        tokens = validate_trace(trace, report, workload, rank, plan)
        logits = matrix(files['logits.json'], workload['decode_tokens'], 512, 'whole logits')
        actual_argmax = [max(range(512), key=row.__getitem__) for row in logits]
        require(actual_argmax == report['runs'][0]['localArgmaxTokens'], 'Captured logits do not reproduce local argmax')
        selected = report['runs'][0]['generatedTokens']
        require(rank != 0 or actual_argmax == selected, 'Selecting rank output tokens differ from its actual argmax')
        require(report['runs'][0]['localArgmaxDisagreementCount'] == sum(x != y for x, y in zip(actual_argmax, selected)), 'Argmax disagreement count differs')
        loaded.append(dict(trace=trace, report=report, tokens=tokens, logits=logits))
    if world == 2:
        a, b = loaded
        for key in ('configurationSHA256', 'parameterLayoutSHA256', 'partitionPlanSHA256', 'promptSHA256', 'teacherSHA256'):
            require(a['report'][key] == b['report'][key], f'Peer {key} differs')
        require(a['report']['runs'][0]['generatedTokens'] == b['report']['runs'][0]['generatedTokens'], 'Peer selected token history differs')
        for ea, eb in zip(a['trace']['events'], b['trace']['events']):
            for key in ('sequence', 'layer', 'path', 'call', 'rows', 'processedTokenStart', 'inputSHA256', 'logitSHA256',
                        'selectedExpertIDs', 'selectedExpertWeights', 'probabilities'):
                require(ea[key] == eb[key], f'{name}: peer router {key} differs at layer{ea["layer"]}/call{ea["call"]}')
        require(original_bytes(a['logits'], 'float32') == original_bytes(b['logits'], 'float32'), f'{name}: peer final logits differ')
    control_directory = out / (name + '-untraced')
    control = read(control_directory / 'run.json')
    require(control == record['untraced_control'], 'Untraced control receipt differs')
    require(control['exit_codes'] == [0] * world and control['bundle_manifest_sha256'] == record['bundle_manifest_sha256'], 'Untraced control completion/bundle differs')
    require(control['traced_logits_exactly_equal_by_rank'] == expected_receipt['untraced_control_logits_equal'] == [True] * world, 'Driver did not verify exact untraced control equality')
    for rank, capture in enumerate(loaded):
        control_report = control['reports'][rank]
        require('routingTraceEnabled' not in control_report, 'Untraced control has routing instrumentation')
        for key in ('rank', 'worldSize', 'mode', 'partition', 'partitionPlanSHA256', 'transport', 'configurationSHA256',
                    'parameterLayoutSHA256', 'promptSHA256', 'teacherSHA256', 'model', 'seed', 'chunkSize',
                    'teacherForced', 'syntheticDType', 'syntheticProfile', 'vocabularySize'):
            require(control_report.get(key) == capture['report'].get(key), f'Untraced control {key} differs')
        require(len(control_report['runs']) == 1, 'Untraced control run count differs')
        for key in ('iteration', 'promptTokens', 'decodeForwardCount', 'decodeInputTokens', 'generatedTokens', 'localArgmaxTokens'):
            require(control_report['runs'][0][key] == capture['report']['runs'][0][key], f'Untraced control {key} differs')
        control_logits = matrix(read(control_directory / f'rank-{rank}/logits.json'), workload['decode_tokens'], 512, 'untraced logits')
        require(original_bytes(control_logits, 'float32') == original_bytes(capture['logits'], 'float32'), 'Capture instrumentation changed actual final logits')
    return dict(name=name, workload=workload, manifest=record['bundle_manifest_sha256'], ranks=loaded)


def describe_token(item):
    event, row = item['event'], item['row']
    return dict(ids=event['selectedExpertIDs'][row], weights=event['selectedExpertWeights'][row],
                logits=event['logits'][row], probabilities=event['probabilities'][row],
                probability_cutoff=event['probabilityCutoff'][row],
                probability_boundary_tie=row in event['probabilityBoundaryTieTokens'],
                logit_boundary_tie=row in event['logitBoundaryTieTokens'])


def compare_execution(baseline, candidate):
    require(baseline['workload'] == candidate['workload'], 'Solo/partition workload differs')
    a, b = baseline['ranks'][0], candidate['ranks'][0]
    for key in ('configurationSHA256', 'promptSHA256', 'teacherSHA256', 'model', 'seed', 'chunkSize', 'syntheticDType', 'syntheticProfile'):
        require(a['report'][key] == b['report'][key], f'Solo/partition {key} differs')
    require(a['tokens'].keys() == b['tokens'].keys(), 'Solo/partition router coordinates differ')
    prompt = baseline['workload']['prompt_tokens']
    details, first_set, first_order = [], None, None
    for event in a['trace']['events']:
        layer = event['layer']
        for row in range(event['rows']):
            position = event['processedTokenStart'] + row
            ai, bi = a['tokens'][(layer, position)], b['tokens'][(layer, position)]
            ae, be = ai['event'], bi['event']
            require((ae['call'], ai['row'], ae['path']) == (be['call'], bi['row'], be['path']), 'Solo/partition call/row/path differs')
            av, bv = describe_token(ai), describe_token(bi)
            aset, bset = set(av['ids']), set(bv['ids'])
            aligned_a, aligned_b = [0.] * 16, [0.] * 16
            for i, w in zip(av['ids'], av['weights']): aligned_a[i] = w
            for i, w in zip(bv['ids'], bv['weights']): aligned_b[i] = w
            record = dict(layer=layer, path=event['path'], call=event['call'], token_within_call=row,
                processed_token_index=position, phase='prefill' if position < prompt else 'decode',
                output_row=(None if position < prompt - 1 else position - (prompt - 1)),
                expert_set_changed=aset != bset, order_only_changed=aset == bset and av['ids'] != bv['ids'],
                aligned_weights_changed=aligned_a != aligned_b, removed_experts=sorted(aset - bset), added_experts=sorted(bset - aset),
                input_error=error(ae['inputs'][row], be['inputs'][bi['row']]),
                router_logit_error=error(av['logits'], bv['logits']), aligned_weight_error=error(aligned_a, aligned_b),
                baseline=av, partitioned=bv)
            details.append(record)
            if record['expert_set_changed'] and first_set is None: first_set = record
            if record['order_only_changed'] and first_order is None: first_order = record
    event_summaries = []
    for ae, be in zip(a['trace']['events'], b['trace']['events']):
        records = [r for r in details if r['layer'] == ae['layer'] and r['call'] == ae['call']]
        event_summaries.append(dict(layer=ae['layer'], path=ae['path'], call=ae['call'], rows=ae['rows'],
            processed_token_start=ae['processedTokenStart'],
            changed_expert_sets=sum(x['expert_set_changed'] for x in records),
            order_only_changes=sum(x['order_only_changed'] for x in records),
            changed_aligned_weights=sum(x['aligned_weights_changed'] for x in records),
            input_error=error(sum(ae['inputs'], []), sum(be['inputs'], [])),
            router_logit_error=error(sum(ae['logits'], []), sum(be['logits'], []))))
    output_rows = []
    for row, (reference, value) in enumerate(zip(a['logits'], b['logits'])):
        output_rows.append(dict(row=row, processed_token_index=prompt - 1 + row,
            phase='final-prompt-token' if row == 0 else 'decode',
            teacher_input=None if row == 0 else baseline['workload']['teacher_tokens'][row - 1],
            error=error(reference, value), baseline_argmax=a['report']['runs'][0]['localArgmaxTokens'][row],
            partitioned_argmax=b['report']['runs'][0]['localArgmaxTokens'][row]))
    peak = max(range(len(output_rows)), key=lambda row: output_rows[row]['error']['relative_rms'])
    def output_context(row):
        return dict(output=output_rows[row], routing=[record for record in details if record['output_row'] == row])
    summaries = []
    for layer in range(4):
        records = [record for record in details if record['layer'] == layer]
        summaries.append(dict(layer=layer, router_token_rows=len(records),
            changed_expert_sets=sum(x['expert_set_changed'] for x in records),
            order_only_changes=sum(x['order_only_changed'] for x in records),
            changed_aligned_weights=sum(x['aligned_weights_changed'] for x in records),
            baseline_probability_boundary_ties=sum(x['baseline']['probability_boundary_tie'] for x in records),
            partitioned_probability_boundary_ties=sum(x['partitioned']['probability_boundary_tie'] for x in records),
            maximum_input_relative_rms=max(x['input_error']['relative_rms'] for x in records),
            maximum_router_logit_relative_rms=max(x['router_logit_error']['relative_rms'] for x in records)))
    return dict(baseline=baseline['name'], candidate=candidate['name'], identities_and_peer_equality_validated=True,
                untraced_control_exact_logits_validated=True, layer_summaries=summaries, event_summaries=event_summaries,
                first_changed_expert_set=first_set, first_order_only_change=first_order,
                all_router_tokens=details, output_rows=output_rows,
                all_decode_positions=[output_context(row) for row in range(1, len(output_rows))],
                peak_output_row=peak, maximum_output_relative_rms=output_rows[peak]['error']['relative_rms'],
                maximum_output_absolute_error=max(x['error']['maximum_absolute_error'] for x in output_rows),
                argmax_agreements=sum(x['baseline_argmax'] == x['partitioned_argmax'] for x in output_rows),
                peak_output_neighborhood=[output_context(row) for row in range(max(0, peak - 1), min(len(output_rows), peak + 2))])


def analyze(out):
    receipt = read(out / 'receipt.json')
    names = [f'{dtype}-{plan}' for dtype in DTYPES for plan in PLANS]
    require(receipt['synthetic_only'] is True and receipt['performance_measurements_valid'] is False, 'Unexpected receipt scope')
    require(sorted(x['name'] for x in receipt['executions']) == sorted(names), 'Expected all six completed capture runs')
    executions = {name: load_execution(out, name, receipt) for name in names}
    require(len({x['manifest'] for x in executions.values()}) == 1, 'Run bundles differ')
    common = [{k: v for k, v in item['workload'].items() if k != 'synthetic_dtype'} for item in executions.values()]
    require(all(x == common[0] for x in common), 'Cross-dtype workload differs')
    comparisons = [compare_execution(executions[f'{dtype}-solo'], executions[f'{dtype}-{plan}']) for dtype in DTYPES for plan in ('ffn', 'full')]
    return dict(schema_version=1, kind='qwen_moe_router_analysis', structural_validation_passed=True,
                synthetic_only=True, performance_measurements_valid=False,
                quality_qualification='diagnostic-only; no BF16 quality pass or broad numerical threshold',
                routing_scope='Stock public-MLX replay from actual captured router logits; private IDs are not intercepted.',
                causality_limit='Correlation under identical teacher history; route changes do not isolate the entire cause of a final logit error.',
                output_row_semantics='Row0 follows final prompt token; rowN>0 follows teacher[N-1]. Router positions are zero-based consumed-token positions.',
                comparison_semantics='Relative RMS uses the baseline vector energy. Expert order is separated from set changes; weights are aligned by global expert ID.',
                untraced_controls='All ten rank outputs exactly match the corresponding uninstrumented one-run, zero-warmup control.',
                original_float_bytes='JSON numbers are rounded back to Float32 before analysis; BF16 representability and original byte SHA256 are verified.',
                binary_sha256=receipt['binary_sha256'], analyzer_sha256=digest(Path(__file__).read_bytes()),
                source_receipt_sha256=digest((out / 'receipt.json').read_bytes()), comparisons=comparisons)


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: analyze-qwen-moe-routing.py OUT')
    out = Path(sys.argv[1]).resolve()
    try:
        result = analyze(out)
    except (ValueError, KeyError, TypeError, IndexError, StopIteration, OSError) as exc:
        result = dict(kind='qwen_moe_router_analysis', structural_validation_passed=False,
                      performance_measurements_valid=False, error=f'{type(exc).__name__}: {exc}')
        (out / 'analysis.json').write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
        raise SystemExit(result['error'])
    (out / 'analysis.json').write_text(json.dumps(result, indent=2, allow_nan=False) + '\n')
    for item in result['comparisons']:
        first = item['first_changed_expert_set']
        first_text = 'none' if first is None else f'layer{first["layer"]}/token{first["processed_token_index"]}'
        count = sum(x['changed_expert_sets'] for x in item['layer_summaries'])
        print(f'{item["candidate"]}: set_changes={count}, first={first_text}, '
              f'peak_row={item["peak_output_row"]}, max_row_RMS={item["maximum_output_relative_rms"]:.9g}, '
              f'max_abs={item["maximum_output_absolute_error"]:.9g}, argmax={item["argmax_agreements"]}/{len(item["output_rows"])}')
    print('Identity, coverage and exact peer checks passed; numerical results are diagnostic-only.')
    print(out / 'analysis.json')


if __name__ == '__main__':
    main()
