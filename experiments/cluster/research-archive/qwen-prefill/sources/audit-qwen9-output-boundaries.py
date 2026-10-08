#!/usr/bin/env python3
"""CPU-only independent replay of saved evidence; never launches native code."""
from pathlib import Path
import datetime
import hashlib
import itertools
import json
import math
import struct
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path('/Users/developer/DarkbloomDev/d-inference')
BASE = Path('/Users/developer/DarkbloomDev/cluster-research/runs/qwen9-output-boundaries-20260913')
OUT = BASE.parent.parent / 'qwen9-output-boundaries-independent-audit-20260913.json'

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def read(path):
    def pairs(items):
        d = {}
        for k, v in items:
            assert k not in d, (path, k)
            d[k] = v
        return d
    def nonfinite(value):
        raise ValueError(value)
    return json.loads(path.read_text(), object_pairs_hook=pairs, parse_constant=nonfinite)

def canonical(value):
    return json.dumps(value, separators=(',', ':'), ensure_ascii=False).encode()

def bf16sha(values):
    raw = bytearray()
    for value in values:
        assert type(value) in (int, float) and math.isfinite(value)
        bits = struct.unpack('<I', struct.pack('<f', value))[0]
        assert bits & 65535 == 0, value
        raw.extend(struct.pack('<H', bits >> 16))
    return hashlib.sha256(raw).hexdigest()

def metrics(a, b):
    assert len(a) == len(b) == 248320
    assert all(type(x) in (int, float) and math.isfinite(x) for x in a + b)
    diffs = [y-x for x, y in zip(a, b)]
    square = math.fsum(x*x for x in diffs)
    maximum = max(map(abs, diffs))
    relative = math.sqrt(square / max(math.fsum(x*x for x in a), 1e-30))
    agree = a.index(max(a)) == b.index(max(b))
    return dict(compared_values=len(a), exact=a == b,
                differing_values=sum(x != y for x, y in zip(a, b)),
                max_absolute=maximum, relative_rms=relative,
                argmax_equal=agree, passed=maximum < .001 and relative < .0001 and agree)

r = read(BASE / 'receipt.json')
assert r['status'] == 'completed' and r['executed_native_calls'] == r['planned_native_calls'] == 6
assert r['correctness_capture_only'] is True and r['throughput_qualification'] is False
assert r['real_loopback_allowed'] is False
assert sha(BASE / 'validate-qwen9-output-boundaries.py') == r['driver_sha256']
assert sha(BASE / 'source-manifest.json') == r['source_manifest_sha256']
source_entries = read(BASE / 'source-manifest.json')
assert len({x['path'] for x in source_entries}) == len(source_entries)
changed = []
for entry in source_entries:
    path = BASE / 'source' / entry['path']
    assert path.stat().st_size == entry['size_bytes'] and sha(path) == entry['sha256'], entry
    if sha(ROOT / entry['path']) != entry['sha256']:
        changed.append(entry['path'])
assert not [name for name in changed if not name.endswith('.md')], changed

sys.path.insert(0, str(BASE / 'source/experiments/cluster'))
from runtime.artifacts import verify_model, verify_files
from runtime.reports import reports
from runtime.configuration import validate

model = Path(r['model_directory'])
assert sha(BASE / 'model-manifest.json') == r['model_manifest_sha256'] == sha(model / 'manifest.json')
aggregate = verify_model(model, r['expected_aggregate_sha256'])
assert aggregate == r['model_verified_aggregate_sha256']
manifest = read(BASE / 'model-manifest.json')
assert sha(BASE / 'bundle/bundle.json') == r['bundle_manifest_sha256']
bundle_entries = read(BASE / 'bundle/bundle.json')['files']
assert verify_files(BASE / 'bundle', bundle_entries) == r['bundle_files']
release = ROOT / 'experiments/cluster/inference/.build/arm64-apple-macosx/release'
assert sha(release / 'cluster-inference') == r['native_binary_sha256'] == r['bundle_files']['cluster-inference']

prompt = read(BASE / 'prompt-96.json')
assert len(prompt) == 96 and read(BASE / 'prompt-65.json') == prompt[:65]
assert read(BASE / 'tokenization.json') == r['tokenization']
tokenization = r['tokenization']
assert tokenization['prompt_ids'] == prompt
assert hashlib.sha256(canonical(prompt)).hexdigest() == tokenization['prompt_sha256']
assert sha(model / 'tokenizer.json') == tokenization['tokenizer_json_sha256']
assert sha(BASE / 'source-text.txt') == tokenization['source_text_sha256']
assert tokenization['chat_template_applied'] is False and tokenization['add_special_tokens'] is False

diagnostics = {}
controls = {}
call_audit = []
expected_policies = {'ordinary-native': ('ordinary', 'native', 'native'),
                    'cbv2-native': ('cbv2-contiguous', 'native', 'native'),
                    'cbv2-ffn-float32': ('cbv2-contiguous', 'native', 'float32'),
                    'cbv2-attention-ffn-float32': ('cbv2-contiguous', 'float32', 'float32')}
for call in r['native_calls']:
    name = call['name']
    assert call['status'] == 'validated' and call['exit_code'] == 0
    launcher = BASE / (name if name.startswith('output-check-') else name+'-launcher')
    for channel in ('stdout', 'stderr'):
        assert sha(launcher / (channel+'.txt')) == call[channel+'_sha256']
    if name.startswith('output-check-'):
        d = read(launcher / 'stdout.txt')
        assert d == call['result']
        count = int(name.rsplit('-', 1)[1])
        assert d['diagnosticOnly'] is True and d['throughputValid'] is False
        assert d['executionPath'] == 'ordinary' and d['syntheticWeights'] is False
        assert d['mtpEnabled'] is False and d['bf16ConversionEnabled'] is True
        assert d['promptTokenIDs'] == prompt[:count]
        assert d['promptSHA256'] == hashlib.sha256(canonical(prompt[:count])).hexdigest()
        assert d['configurationSHA256'] == sha(model / 'config.json')
        assert d['evaluatedChunkWidths'] == ([32, 32, 1] if count == 65 else [32, 32, 32])
        for key in ('normAfterFull', 'normAfterSlice'):
            assert bf16sha(d[key+'Values']) == d[key]['logicalBytesSHA256']
        assert d['normAfterFullValues'] == d['normAfterSliceValues']
        args = dict(zip(call['command'][1::2], call['command'][2::2]))
        assert args['--mode'] == 'qwen-output-check'
        assert args['--model-dir'] == str(model) and args['--prompt-tokens'] == str(count)
        assert args['--execution-path'] == 'ordinary'
        assert all(args['--'+field+'-precision'] == 'native' for field in ('attention-output', 'ffn-output', 'ffn-branch'))
        diagnostics[count] = d
        call_audit.append(dict(name=name, report_kind=d['kind'], memory_peak_reported=False,
                               config_sha256=d['configurationSHA256'], layout_sha256=d['parameterLayoutSHA256']))
        continue
    directory = BASE / name
    assert sha(BASE / (name+'.spec.json')) == call['spec_sha256']
    spec = validate(read(BASE / (name+'.spec.json')))
    run = read(directory / 'run.json')
    assert run['spec'] == spec and spec['backend'] == 'solo' and len(spec['ranks']) == 1
    assert spec['artifact_aggregate_sha256'] == aggregate and spec['workload']['synthetic'] is False
    assert run['verified_execution'] is True and run['hardware_throughput_candidate'] is False
    assert run['exit_codes'] == [0] and run['cancellation_reason'] is None
    assert sha(directory / 'run.json') == call['run_sha256']
    assert sha(directory / 'bundle/bundle.json') == r['bundle_manifest_sha256']
    assert verify_files(directory / 'bundle', bundle_entries) == r['bundle_files']
    assert reports(run['ranks'], spec) == run['reports']
    report = run['reports'][0]
    result = report['runs'][0]
    assert (report['executionPath'], report['attentionOutputPrecision'], report['ffnOutputPrecision']) == expected_policies[name]
    assert report['ffnBranchPrecision'] == 'native'
    assert report['schemaVersion'] == 9 and report['worldSize'] == 1 and report['rank'] == 0
    assert report['partition'] == report['transport'] == 'none'
    assert report['configurationSHA256'] == sha(model / 'config.json')
    assert report['parameterLayoutSHA256'] == diagnostics[96]['parameterLayoutSHA256']
    assert report['embeddingActivationDType'] == 'bfloat16' and report['ffnScaleDTypes'] == ['bfloat16']
    assert report['bf16ConversionEnabled'] is True and report['syntheticWeights'] is False
    assert report['modelFamily'] == 'qwen35' and report['feedForwardKind'] == 'dense' and report['mtpEnabled'] is False
    assert spec['workload']['prompt_ids'] == prompt and spec['workload']['chunk_size'] == 32
    assert spec['workload']['warmups'] == 0 and spec['workload']['repeats'] == 1
    for file, digest in call['rank_evidence_sha256'].items():
        assert sha(directory / file) == digest
    rank = read(directory / 'rank-0/rank.json')
    assert rank['artifact_aggregate_sha256'] == aggregate and rank['model_directory'] == str(model)
    assert rank['environment']['DARKBLOOM_BF16_WEIGHTS'] == '1'
    arguments = dict(zip(rank['arguments'][::2], rank['arguments'][1::2]))
    assert arguments['--mode'] == 'baseline'
    assert (arguments['--execution-path'], arguments['--attention-output-precision'], arguments['--ffn-output-precision']) == expected_policies[name]
    logits = read(directory / 'rank-0/logits.json')
    assert len(logits) == 4 and all(len(row) == 248320 for row in logits)
    argmax = [row.index(max(row)) for row in logits]
    assert argmax == result['generatedTokens'] == result['localArgmaxTokens'] == [4087, 13, 271, 1206]
    assert result['decodeInputTokens'] == [4087, 13, 271]
    assert report['teacherForced'] == (name != 'ordinary-native')
    assert result['peakMLXBytes'] == call['peakMLXBytes'] and result['activeMLXBytes'] == call['activeMLXBytes']
    if name != 'ordinary-native':
        assert read(directory / 'rank-0/teacher.json') == [4087, 13, 271]
    controls[name] = logits
    call_audit.append(dict(name=name, execution_path=report['executionPath'], attention_output_precision=report['attentionOutputPrecision'],
                          ffn_output_precision=report['ffnOutputPrecision'], teacher_forced=report['teacherForced'],
                          generated_tokens=argmax, peak_MLX_bytes=result['peakMLXBytes'], active_MLX_bytes=result['activeMLXBytes'],
                          native_correctness_only=report['correctnessOnly'], native_throughput_measurement_valid=report['throughputMeasurementValid']))

comparisons = []
for (left, a), (right, b) in itertools.combinations(controls.items(), 2):
    rows = [dict(row=i, **metrics(x, y)) for i, (x, y) in enumerate(zip(a, b))]
    calculated = dict(reference=left, candidate=right, same_execution_path=expected_policies[left][0] == expected_policies[right][0],
                      identical_consumed_history=True, generated_tokens_equal=True, exact=a == b,
                      passed=all(row['passed'] for row in rows), rows=rows)
    saved = next(c for c in r['comparisons'] if c['reference'] == left and c['candidate'] == right)
    assert calculated == saved, (left, right)
    comparisons.append(calculated)

# Independently bind the diagnostic's actual norm/head tensor bytes to the verified checkpoint.
tensor_names = {'language_model.model.norm.weight': 'normWeight', 'language_model.lm_head.weight': 'headWeight',
                'language_model.lm_head.scales': 'headScales', 'language_model.lm_head.biases': 'headBiases'}
tensor_audit = []
for file in sorted(model.glob('*.safetensors')):
    with file.open('rb') as stream:
        length = struct.unpack('<Q', stream.read(8))[0]
        header = json.loads(stream.read(length))
        for name, field in tensor_names.items():
            if name not in header:
                continue
            descriptor = header[name]
            lo, hi = descriptor['data_offsets']
            stream.seek(8 + length + lo)
            remaining, digest = hi-lo, hashlib.sha256()
            while remaining:
                block = stream.read(min(remaining, 1024*1024))
                assert block
                digest.update(block); remaining -= len(block)
            for d in diagnostics.values():
                assert digest.hexdigest() == d[field]['logicalBytesSHA256']
                assert descriptor['shape'] == d[field]['shape']
            tensor_audit.append(dict(name=name, source_file=file.name, bytes=hi-lo, sha256=digest.hexdigest(), dtype=descriptor['dtype']))
assert len(tensor_audit) == 4

d = diagnostics[96]
ordinary_hash = bf16sha(controls['ordinary-native'][0])
cbv2_hash = bf16sha(controls['cbv2-native'][0])
assert ordinary_hash == d['ordinaryFullLast']['tensor']['logicalBytesSHA256'] == d['recomputedFullLast']['tensor']['logicalBytesSHA256']
assert cbv2_hash == d['sliceAfterNormBeforeHead']['tensor']['logicalBytesSHA256'] == d['sliceBeforeNormAndHead']['tensor']['logicalBytesSHA256']
assert d['headFullVersusSingleRow'] == d['ordinaryVersusFullyNarrowed']
first = comparisons[0]['rows'][0]
assert first['differing_values'] == d['headFullVersusSingleRow']['differingValues'] == 100298
assert first['max_absolute'] == d['headFullVersusSingleRow']['maximumAbsoluteError'] == .125
assert math.isclose(first['relative_rms'], d['headFullVersusSingleRow']['relativeRMSError'], rel_tol=1e-8)
for d in diagnostics.values():
    assert all(d[key]['exactValues'] for key in ('originalVersusRecomputedFull', 'normFullVersusSliced', 'narrowedNormContribution'))
    assert len({d[key]['argmaxToken'] for key in ('ordinaryFullLast', 'recomputedFullLast', 'sliceAfterNormBeforeHead', 'sliceBeforeNormAndHead')}) == 1
assert len({diagnostics[65][key]['tensor']['logicalBytesSHA256'] for key in
            ('ordinaryFullLast', 'recomputedFullLast', 'sliceAfterNormBeforeHead', 'sliceBeforeNormAndHead')}) == 1
assert diagnostics[65]['headFullVersusSingleRow']['exactValues'] is True
assert diagnostics[65]['ordinaryVersusFullyNarrowed']['exactValues'] is True

audit = dict(schema_version=1, audited_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
             scope='CPU-only replay of saved execution evidence; no native/model execution',
             receipt_sha256=sha(BASE/'receipt.json'), audit_script_sha256=sha(Path(__file__)),
             all_assertions_passed=True, native_calls=6, one_shot_controls=4, standalone_diagnostics=2,
             aggregate_sha256=aggregate, model_file_count=manifest['file_count'], model_bytes=manifest['total_size_bytes'],
             source_manifest_sha256=r['source_manifest_sha256'], source_file_count=len(source_entries),
             source_snapshot_matches_current_executable_sources=True, changed_documentation_paths=changed,
             native_binary_sha256=r['native_binary_sha256'], staged_native_matches_current_release=True,
             bundle_manifest_sha256=r['bundle_manifest_sha256'], call_audit=call_audit, comparisons= comparisons,
             pairwise_comparisons=6, compared_rows=24, compared_values=24*248320,
             passing_pairs=0, passing_rows=3, exact_rows=3, argmax_disagreements=0,
             same_hidden_head_evidence=dict(verified_checkpoint_tensor_bytes=tensor_audit,
                 prompt96_ordinary_row0_bf16_sha256=ordinary_hash, prompt96_cbv2_row0_bf16_sha256=cbv2_hash,
                 norm_rows_exact=True, full_and_narrowed_head_match_independent_control_hashes=True,
                 head_only_differing_values=100298, head_only_maximum_absolute_error=.125,
                 relative_rms=first['relative_rms'], prompt65_one_row_all_exact=True,
                 limitation='Proves same-hidden head-shape sensitivity and reproduction of observed first-row difference; does not observe CBv2 hidden/cache equality or prove a unique internal kernel cause.'),
             memory_semantics=dict(measurement='peak active MLX allocator bytes after execute() resets peak, including resident model buffers at subsequent allocations',
                 includes=['resident loaded model buffers', 'live request/state/workspace allocations', 'MLX logits-capture conversion arrays', 'lazy precision metadata casts evaluated during request'],
                 excludes=['earlier loading/construction peak', 'free allocator cache', 'Swift/Python host arrays and JSON', 'process RSS/OS/compressor and other applications'],
                 standalone_diagnostics_peak=None,
                 source=['Benchmark.swift:36,112', 'Main.swift:70,161', 'MLX/Memory.swift:224', 'metal/allocator.h:34', 'metal/allocator.cpp:220']),
             interpretation=dict(correctness_capture_only=True, throughput_qualified=False, distributed_execution_tested=False,
                 full_quality_qualified=False, candidate_policy_departure='Compare cbv2-native versus wider cbv2 policies; widening shifts all four rows and is independent of head narrowing.',
                 teacher_history='Ordinary greedy first run; later controls consume its first three tokens. All four row argmax tokens agree in this bounded sample.',
                 flags='Native solo reports truthfully retain throughputMeasurementValid=true and correctnessOnly=false; enclosing experiment explicitly disclaims throughput qualification, and launcher hardware_throughput_candidate=false.'))
OUT.write_text(json.dumps(audit, indent=2)+'\n')
print(json.dumps({k:audit[k] for k in ('all_assertions_passed','native_calls','source_file_count','pairwise_comparisons','compared_rows','compared_values','passing_pairs','passing_rows','argmax_disagreements')}))
print(OUT)
