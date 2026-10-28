#!/usr/bin/env python3
"""Six bounded, offline real-Qwen9 numerical diagnostics; no throughput qualification.

The parent agent runs this only after the native build is complete. --prepare-only
archives and verifies inputs but does not launch native inference. Native calls
run sequentially, with 170-second internal and 180-second outer deadlines.
"""
import argparse
import datetime
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
REPO = Path('/Users/developer/DarkbloomDev/d-inference').resolve()
CLUSTER = REPO / 'experiments/cluster'
RELEASE = CLUSTER / 'inference/.build/arm64-apple-macosx/release'
MODEL = Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B').resolve()
TOKENIZER_PYTHON = Path('/Users/developer/.darkbloom/python/bin/python3')
AGGREGATE = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
TOKENIZER_SHA = '87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4'
PREFIX_SHA = '4c1f00887775d26c29e398bc54e2b37501614599455df2f3b83c5544608b3612'
TEXT = (
    'A research team is comparing two ways to process a long sequence of words. '
    'The first method computes an answer for every position and keeps only the final answer. '
    'The second method carries out the same internal work but computes the final answer only once. '
    'In exact arithmetic these methods should agree, but computers store numbers with limited precision. '
    'A useful experiment therefore keeps the input, the model weights, and the intermediate values fixed. '
    'It changes only the shape of the final calculation, then records the resulting numbers before drawing a conclusion. '
    'The team repeats the calculation with one row and with several rows, checking normalization separately from matrix multiplication. '
    'They also record the memory required by each run and keep the original observations so another researcher can reproduce the comparison. '
    'This short passage is ordinary prose used as a numerical test input. It does not request a conversation, a factual answer, or a judgement about writing quality.')
GATE = dict(max_absolute_strictly_less_than=.001, row_relative_rms_strictly_less_than=.0001,
            every_row_argmax_equal=True)
DEPENDENCY_FILES = [
    'libs/mlx-swift-lm/Package.swift',
    'libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift',
    'libs/mlx-swift-lm/Libraries/MLXLLM/LLMModel.swift',
    'libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/SteppableAdapterV2.swift',
    'libs/mlx-swift/Source/MLXNN/Normalization.swift',
    'libs/mlx-swift/Source/MLXNN/Quantized.swift',
    'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/quantized.cpp',
    'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/normalization.cpp',
    'libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels/quantized.h',
]


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def canonical(value):
    return json.dumps(value, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def read_json(path):
    def closed(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f'Duplicate JSON key: {key}')
            result[key] = value
        return result
    def nonfinite(value):
        raise ValueError(f'Nonfinite JSON constant: {value}')
    return json.loads(Path(path).read_text(), object_pairs_hook=closed, parse_constant=nonfinite)


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + '\n')
    temporary.replace(path)


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def compare(left, right):
    require(len(left) == len(right) == 4, 'Expected four complete logit rows')
    rows = []
    for index, (a, b) in enumerate(zip(left, right, strict=True)):
        require(isinstance(a, list) and isinstance(b, list) and len(a) == len(b) > 0,
                'Logit row dimensions differ')
        require(all(finite_number(value) for value in a + b), 'Logits must be finite numbers, not booleans')
        differences = [float(y) - float(x) for x, y in zip(a, b, strict=True)]
        squares = math.fsum(value * value for value in differences)
        reference = math.fsum(float(value) ** 2 for value in a)
        maximum = max(map(abs, differences))
        rms = math.sqrt(squares / max(reference, 1e-30))
        greedy = a.index(max(a)) == b.index(max(b))
        rows.append(dict(row=index, compared_values=len(a), exact=a == b,
            differing_values=sum(x != y for x, y in zip(a, b, strict=True)),
            max_absolute=maximum, relative_rms=rms, argmax_equal=greedy,
            passed=maximum < .001 and rms < .0001 and greedy))
    return dict(exact=left == right, passed=all(row['passed'] for row in rows), rows=rows)


def environment():
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('MLX_', 'JACCL_', 'DARKBLOOM_'))}
    env.update(DARKBLOOM_BF16_WEIGHTS='1', HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
               TOKENIZERS_PARALLELISM='false', PYTHONDONTWRITEBYTECODE='1')
    return env


def kill_owned_tree(pid):
    # Supervisors create their own sessions; killing only the launcher group
    # would leave native children alive. Inspect this process's descendants only.
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid='], text=True).splitlines()
    pairs = [tuple(map(int, row.split())) for row in rows]
    owned, frontier = [pid], [pid]
    while frontier:
        frontier = [child for child, parent in pairs if parent in frontier and child not in owned]
        owned.extend(frontier)
    for child in reversed(owned):
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return owned


def bounded(command, directory, env, receipt_entry):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    receipt_entry.update(command=command, started_at=now(), outer_timeout_seconds=180)
    start = time.monotonic()
    with (directory / 'stdout.txt').open('wb') as stdout, (directory / 'stderr.txt').open('wb') as stderr:
        child = subprocess.Popen(command, cwd=directory, env=env, stdin=subprocess.DEVNULL,
                                 stdout=stdout, stderr=stderr, start_new_session=True)
        receipt_entry['launcher_pid'] = child.pid
        try:
            code = child.wait(timeout=180)
        except BaseException:
            receipt_entry['terminated_owned_pids'] = kill_owned_tree(child.pid)
            child.wait()
            raise
        finally:
            receipt_entry.update(wall_seconds=time.monotonic() - start, finished_at=now(),
                stdout_sha256=sha(directory / 'stdout.txt'), stderr_sha256=sha(directory / 'stderr.txt'))
    receipt_entry['exit_code'] = code
    require(code == 0, f'Native diagnostic/launcher exited {code}: {directory}')


def snapshot_sources(output):
    names = subprocess.check_output(['rg', '--files', 'experiments/cluster'], cwd=REPO, text=True).splitlines()
    entries = []
    for name in sorted(names + DEPENDENCY_FILES):
        source = REPO / name
        target = output / 'source' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        entries.append(dict(path=name, size_bytes=target.stat().st_size, sha256=sha(target)))
    write_json(output / 'source-manifest.json', entries)
    dependencies = {}
    for name in ('libs/mlx-swift-lm', 'libs/mlx-swift', 'libs/mlx-swift/Source/Cmlx/mlx'):
        dependencies[name] = dict(
            head=subprocess.check_output(['git', '-C', str(REPO / name), 'rev-parse', 'HEAD'], text=True).strip(),
            status=subprocess.check_output(['git', '-C', str(REPO / name), 'status', '--porcelain'], text=True))
    return entries, dependencies


def verify_sources(output, entries):
    for entry in entries:
        require(sha(output / 'source' / entry['path']) == entry['sha256'], 'Archived source changed')
        # Documentation may evolve separately; executable source must stay bound.
        if Path(entry['path']).suffix != '.md':
            require(sha(REPO / entry['path']) == entry['sha256'], f'Current source changed: {entry["path"]}')


def tokenize(output, env):
    require(sha(MODEL / 'tokenizer.json') == TOKENIZER_SHA, 'Tokenizer is not the registered artifact')
    (output / 'source-text.txt').write_text(TEXT)
    code = """from tokenizers import Tokenizer
import tokenizers,json,platform,sys
from pathlib import Path
t=Tokenizer.from_file(sys.argv[1]);text=Path(sys.argv[2]).read_text()
ids=t.encode(text,add_special_tokens=False).ids
print(json.dumps(dict(tokenizer_version=tokenizers.__version__,python_version=platform.python_version(),
 total_tokens=len(ids),prompt_ids=ids[:96],prefix_text=t.decode(ids[:96],skip_special_tokens=False))))
"""
    process = subprocess.run([str(TOKENIZER_PYTHON), '-c', code, str(MODEL / 'tokenizer.json'),
                              str(output / 'source-text.txt')], env=env, capture_output=True, text=True,
                             timeout=30, check=True)
    result = json.loads(process.stdout)
    ids = result['prompt_ids']
    require(len(ids) == 96 and all(type(value) is int and value >= 0 for value in ids), 'Invalid token prefix')
    require(hashlib.sha256(canonical(ids)).hexdigest() == PREFIX_SHA, 'Offline token prefix changed')
    result.update(tokenizer_json_sha256=TOKENIZER_SHA, prompt_sha256=PREFIX_SHA,
        source_text_sha256=sha(output / 'source-text.txt'), add_special_tokens=False,
        chat_template_applied=False, python_executable=str(TOKENIZER_PYTHON),
        python_executable_sha256=sha(TOKENIZER_PYTHON.resolve()), tokenizer_script=code)
    write_json(output / 'tokenization.json', result)
    write_json(output / 'prompt-96.json', ids)
    write_json(output / 'prompt-65.json', ids[:65])
    return ids, result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New directory outside the Git repository')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    require(not output.is_relative_to(REPO) and not output.exists(), 'Output must be new and outside Git')
    output.mkdir(mode=0o700, parents=True)
    shutil.copy2(__file__, output / Path(__file__).name)
    receipt = dict(schema_version=1, started_at=now(), status='preparing', native_calls=[], comparisons=[],
        driver_sha256=sha(__file__), model_directory=str(MODEL), expected_aggregate_sha256=AGGREGATE,
        correctness_capture_only=True, throughput_qualification=False, real_loopback_allowed=False,
        planned_native_calls=6, strict_diagnostic_gate=GATE,
        limitations=['Single device and one fixed prose prefix; no chat template or model-quality claim.',
                     'Teacher forcing after the ordinary control fixes history; controls are not free-running comparisons.',
                     'Numeric gate failures are recorded and do not abort the remaining controls.',
                     'Saved native timing fields are not treated as sustained throughput evidence.',
                     'Experiment sources and selected dependency seams are archived; dependency metadata is not a full build attestation.'])
    save = lambda: write_json(output / 'receipt.json', receipt)
    save()
    try:
        sources, dependencies = snapshot_sources(output)
        receipt.update(source_manifest_sha256=sha(output / 'source-manifest.json'), dependencies=dependencies)
        verify_sources(output, sources)
        sys.path.insert(0, str(CLUSTER))
        from runtime.artifacts import verify_model, verify_files
        from runtime.bundle import snapshot
        from runtime.configuration import validate
        from runtime.reports import read_report, reports
        receipt['bundle_manifest_sha256'] = snapshot(RELEASE, output / 'bundle')
        bundle_entries = read_json(output / 'bundle/bundle.json')['files']
        receipt['bundle_files'] = verify_files(output / 'bundle', bundle_entries)
        receipt['native_binary_sha256'] = receipt['bundle_files']['cluster-inference']
        receipt['model_verified_aggregate_sha256'] = verify_model(MODEL, AGGREGATE)
        receipt['model_verified_at'] = now()
        shutil.copy2(MODEL / 'manifest.json', output / 'model-manifest.json')
        receipt['model_manifest_sha256'] = sha(output / 'model-manifest.json')
        env = environment()
        prompt, tokenizer = tokenize(output, env)
        receipt['tokenization'] = tokenizer
        vocabulary = read_json(MODEL / 'config.json')['text_config']['vocab_size']
        require(all(value < vocabulary for value in prompt), 'Prompt token exceeds vocabulary')
        receipt['environment_policy'] = dict(DARKBLOOM_BF16_WEIGHTS='1', offline=True,
            inherited_MLX_JACCL_DARKBLOOM_variables_removed=True)
        receipt['vocabulary_size'] = vocabulary
        receipt['status'] = 'prepared_not_executed' if args.prepare_only else 'running'
        save()
        if args.prepare_only:
            print(json.dumps(dict(output=str(output), status=receipt['status'], native_calls=0)))
            return 0

        def before_call(name):
            require(len(receipt['native_calls']) < 6, 'Native call budget exhausted')
            verify_sources(output, sources)
            require(verify_files(output / 'bundle', bundle_entries) == receipt['bundle_files'], 'Bundle changed')
            entry = dict(name=name, status='started')
            receipt['native_calls'].append(entry); save()
            return entry

        checks = []
        for count in (65, 96):
            entry = before_call(f'output-check-{count}')
            verify_model(MODEL, AGGREGATE)
            command = [str(output / 'bundle/cluster-inference'), '--mode', 'qwen-output-check',
                '--model-dir', str(MODEL), '--tokens-file', str(output / f'prompt-{count}.json'),
                '--prompt-tokens', str(count), '--chunk-size', '32', '--decode-tokens', '1',
                '--repeats', '1', '--warmups', '0', '--seed', '7', '--timeout-seconds', '170',
                '--execution-path', 'ordinary', '--attention-output-precision', 'native',
                '--ffn-output-precision', 'native', '--ffn-branch-precision', 'native']
            directory = output / entry['name']
            bounded(command, directory, env, entry)
            result = read_report(directory / 'stdout.txt')
            for key, expected in dict(schemaVersion=1, kind='qwen_output_narrowing_check', diagnosticOnly=True,
                    throughputValid=False, executionPath='ordinary', mtpEnabled=False, syntheticWeights=False,
                    bf16ConversionEnabled=True, chunkSize=32, promptTokenIDs=prompt[:count]).items():
                require(type(result.get(key)) is type(expected) and result[key] == expected, f'Invalid narrowing {key}')
            require(result['promptSHA256'] == hashlib.sha256(canonical(prompt[:count])).hexdigest(), 'Narrowing prompt differs')
            require(result['configurationSHA256'] == sha(MODEL / 'config.json'), 'Narrowing config differs')
            require(result['evaluatedChunkWidths'] == ([32, 32, 1] if count == 65 else [32, 32, 32]), 'Wrong narrowing tail')
            for key in ('normAfterFullValues', 'normAfterSliceValues'):
                require(all(finite_number(value) for value in result[key]), 'Nonfinite narrowing norm row')
            for key in ('originalVersusRecomputedFull', 'normFullVersusSliced', 'headFullVersusSingleRow',
                        'narrowedNormContribution', 'ordinaryVersusFullyNarrowed'):
                require(all(finite_number(result[key][field]) for field in
                    ('maximumAbsoluteError', 'rootMeanSquareError', 'relativeRMSError')), 'Invalid narrowing metric')
            for key in ('ordinaryFullLast', 'recomputedFullLast', 'sliceAfterNormBeforeHead', 'sliceBeforeNormAndHead'):
                require(type(result[key]['argmaxToken']) is int and 0 <= result[key]['argmaxToken'] < vocabulary
                        and finite_number(result[key]['argmaxValue']), 'Invalid narrowing argmax')
            checks.append(result)
            entry.update(status='validated', result=result, peakMLXBytes=result.get('peakMLXBytes'),
                         peak_note='Available only if exposed by this standalone native diagnostic')
            save()
        for field in ('configurationSHA256', 'parameterLayoutSHA256', 'normWeight', 'headWeight', 'headScales', 'headBiases'):
            require(checks[0][field] == checks[1][field], f'Narrowing parameter identity differs: {field}')

        controls = {}; baseline_tokens = None
        policies = [('ordinary-native', 'ordinary', 'native', 'native'),
                    ('cbv2-native', 'cbv2-contiguous', 'native', 'native'),
                    ('cbv2-ffn-float32', 'cbv2-contiguous', 'native', 'float32'),
                    ('cbv2-attention-ffn-float32', 'cbv2-contiguous', 'float32', 'float32')]
        for name, path, attention, ffn in policies:
            entry = before_call(name)
            work = dict(synthetic=False, prompt_ids=prompt, prompt_tokens=96, chunk_size=32,
                decode_tokens=4, repeats=1, warmups=0, seed=7, execution_path=path,
                attention_output_precision=attention, ffn_output_precision=ffn, ffn_branch_precision='native')
            if baseline_tokens is not None:
                work['teacher_tokens'] = baseline_tokens[:3]
            spec = validate(dict(schema_version=1, backend='solo', partition='ffn',
                ranks=[dict(location='local', model_directory=str(MODEL))],
                artifact_aggregate_sha256=AGGREGATE, timeout_seconds=170, capture_logits=True, workload=work))
            spec_path = output / f'{name}.spec.json'; write_json(spec_path, spec)
            # Use the current launcher only after matching it to the saved source.
            directory = output / name
            command = [sys.executable, str(CLUSTER / 'run_inference.py'), '--spec', str(spec_path),
                       '--bundle', str(output / 'bundle'), '--output', str(directory)]
            bounded(command, output / f'{name}-launcher', env, entry)
            record = read_json(directory / 'run.json')
            require(record.get('verified_execution') is True and record.get('hardware_throughput_candidate') is False
                    and record['spec'] == spec and record['exit_codes'] == [0], 'Unverified real solo execution')
            actual = reports(record['ranks'], spec)
            require(actual == record['reports'] and len(actual) == 1, 'Report reconstruction differs')
            report = actual[0]; run = report['runs'][0]
            require(report['schemaVersion'] == 9 and report['modelFamily'] == 'qwen35'
                    and report['feedForwardKind'] == 'dense' and report['vocabularySize'] == vocabulary, 'Wrong native schema/model')
            for field in ('configurationSHA256', 'parameterLayoutSHA256', 'embeddingActivationDType', 'ffnScaleDTypes'):
                require(report[field] == checks[1][field], f'Control model identity differs: {field}')
            manifest_path = directory / 'bundle/bundle.json'
            require(sha(manifest_path) == record['bundle_manifest_sha256'], 'Run bundle manifest changed')
            require(verify_files(directory / 'bundle', read_json(manifest_path)['files']) == receipt['bundle_files'], 'Run bundle differs')
            values = read_json(directory / 'rank-0/logits.json')
            require(len(values) == 4 and all(isinstance(row, list) and len(row) == vocabulary for row in values), 'Incomplete logits')
            compare(values, values)
            require([row.index(max(row)) for row in values] == run['localArgmaxTokens'] == run['generatedTokens'], 'Logits disagree with reported selection')
            if baseline_tokens is None:
                require(report['teacherForced'] is False and run['decodeInputTokens'] == run['generatedTokens'][:3], 'Baseline must be autoregressive')
                baseline_tokens = run['generatedTokens']; write_json(output / 'baseline-teacher.json', baseline_tokens[:3])
            else:
                require(report['teacherForced'] is True and run['decodeInputTokens'] == baseline_tokens[:3], 'Control history is not bound to baseline')
            entry.update(status='validated', spec_sha256=sha(spec_path), run_sha256=sha(directory / 'run.json'),
                logits_sha256=sha(directory / 'rank-0/logits.json'), bundle_manifest_sha256=record['bundle_manifest_sha256'],
                generated_tokens=run['generatedTokens'], decode_input_tokens=run['decodeInputTokens'],
                peakMLXBytes=run['peakMLXBytes'], activeMLXBytes=run['activeMLXBytes'],
                rank_evidence_sha256={str(path.relative_to(directory)): sha(path)
                    for path in sorted((directory / 'rank-0').iterdir()) if path.is_file()},
                native_timing_fields_retained_only_as_diagnostics=True)
            controls[name] = (values, report)
            receipt['comparisons'] = []
            for left, right in itertools.combinations(controls, 2):
                a, ar = controls[left]; b, br = controls[right]
                receipt['comparisons'].append(dict(reference=left, candidate=right,
                    same_execution_path=ar['executionPath'] == br['executionPath'], identical_consumed_history=True,
                    generated_tokens_equal=ar['runs'][0]['generatedTokens'] == br['runs'][0]['generatedTokens'], **compare(a, b)))
            save()
        verify_sources(output, sources)
        verify_model(MODEL, AGGREGATE)
        receipt.update(status='completed', finished_at=now(), executed_native_calls=len(receipt['native_calls']),
            numeric_gate_failures=sum(not item['passed'] for item in receipt['comparisons']),
            all_execution_and_identity_checks_passed=True, baseline_teacher_tokens=baseline_tokens[:3])
        save()
        print(json.dumps(dict(output=str(output), status=receipt['status'],
                             numeric_gate_failures=receipt['numeric_gate_failures'], native_calls=6)))
        return 0
    except BaseException as error:
        receipt.update(status='failed', finished_at=now(), error=f'{type(error).__name__}: {error}')
        save()
        raise


if __name__ == '__main__':
    sys.exit(main())
