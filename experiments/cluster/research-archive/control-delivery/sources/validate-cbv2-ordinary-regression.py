#!/usr/bin/env python3
"""Replay six archived Gemma workloads through the refactored ordinary path.

No production model, SSH, RDMA, sampling-quality or performance qualification.
--prepare-only verifies all inputs using CPU/file IO and never starts inference.
Without that flag, cases run sequentially through the matching archived launcher.
"""
import argparse
import copy
import datetime
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys


INPUTS = Path(__file__).with_suffix('.inputs.json')
INPUTS_SHA256 = 'edab265634c3000af151b06efd496f7a37b0d2c68c7bc60bd05d4e936096ff5f'
REPOSITORY = Path('/Users/developer/DarkbloomDev/d-inference').resolve()
IDENTITY_FIELDS = (
    'model', 'modelFamily', 'configurationSHA256', 'parameterLayoutSHA256',
    'promptSHA256', 'teacherSHA256', 'teacherForced', 'seed', 'syntheticWeights',
    'syntheticProfile', 'syntheticDType', 'embeddingActivationDType', 'ffnScaleDTypes',
    'attentionOutputPrecision', 'ffnBranchPrecision', 'feedForwardKind',
    'partition', 'partitionPlanSHA256', 'partitionStorage', 'rank', 'worldSize',
    'tokenSelectionPolicy', 'mtpEnabled', 'chunkSize', 'vocabularySize',
)
RESULT_FIELDS = (
    'iteration', 'promptTokens', 'decodeForwardCount', 'generatedTokens',
    'localArgmaxTokens', 'localArgmaxDisagreementCount', 'decodeInputTokens',
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def read_json(path):
    def reject_constant(value):
        raise ValueError(f'Nonfinite JSON constant: {value}')
    return json.loads(Path(path).read_text(), parse_constant=reject_constant)


def verify_hash(path, expected):
    require(digest(path) == expected, f'Archived input changed: {path}')


def safe_relative(root, name):
    path = (root / name).resolve()
    require(path.is_relative_to(root.resolve()), f'Invalid manifest path: {name}')
    return path


def verify_source(archive, expected_manifest):
    manifest = archive / 'source-manifest.json'
    verify_hash(manifest, expected_manifest)
    for entry in read_json(manifest):
        relative = Path(entry['path']).relative_to('experiments/cluster')
        verify_hash(safe_relative(archive / 'source', relative), entry['sha256'])


def verify_historical_bundle(case_dir, run):
    manifest = case_dir / 'bundle/bundle.json'
    verify_hash(manifest, run['bundle_manifest_sha256'])
    for entry in read_json(manifest)['files']:
        path = safe_relative(case_dir / 'bundle', entry['path'])
        require(path.stat().st_size == entry['size_bytes'], f'Archived bundle size changed: {path}')
        verify_hash(path, entry['sha256'])


def verify_current(plan):
    archive = Path(plan['current_archive'])
    verify_source(archive, plan['current_source_manifest_sha256'])
    for name, expected in plan['current_bundle_files'].items():
        verify_hash(safe_relative(archive / 'bundle', name), expected)


def load_references(plan):
    references = []
    checked_archives = set()
    for case in plan['cases']:
        archive = Path(case['archive'])
        for name, expected in case['reference_files'].items():
            verify_hash(safe_relative(archive, name), expected)
        if archive not in checked_archives:
            verify_source(archive, case['reference_files']['source-manifest.json'])
            checked_archives.add(archive)
        case_dir = archive / case['name']
        run = read_json(case_dir / 'run.json')
        require(run.get('verified_execution') is True and run.get('hardware_throughput_candidate') is False,
                f'Historical execution is not a verified synthetic control: {case_dir}')
        verify_historical_bundle(case_dir, run)
        require(digest(case_dir / 'bundle/cluster-inference') == case['historical_binary_sha256'],
                'Historical native identity differs')
        spec = copy.deepcopy(run['spec'])
        require(spec['backend'] in ('solo', 'loopback-test') and spec['capture_logits'] is True
                and all(rank == {'location': 'local'} for rank in spec['ranks'])
                and spec['workload']['synthetic'] is True
                and spec['workload']['synthetic_profile'] in ('gemma-moe', 'gemma-moe-w8')
                and spec['workload']['repeats'] == 1 and spec['workload']['warmups'] == 0,
                'Historical fixture is outside the bounded local regression scope')
        require('execution_path' not in spec['workload'], 'Historical execution-path assumption changed')
        spec['workload']['execution_path'] = 'ordinary'
        require(len(run['reports']) == len(spec['ranks']), 'Historical rank count mismatch')
        for report in run['reports']:
            require(report['schemaVersion'] == 7 and report['modelFamily'] == 'gemma4',
                    'Expected historical schema7 Gemma reference')
        references.append((case, spec, run))
    require(len(references) == 6, 'The bounded regression matrix must contain exactly six cases')
    return references


def compare_logits(reference, candidate, outputs, vocabulary):
    require(isinstance(reference, list) and isinstance(candidate, list)
            and len(reference) == len(candidate) == outputs, 'Logit row count changed')
    rows = []
    for index, (left, right) in enumerate(zip(reference, candidate, strict=True)):
        require(isinstance(left, list) and isinstance(right, list) and len(left) == len(right) == vocabulary,
                'Logit vocabulary shape changed')
        require(all(type(value) in (int, float) and math.isfinite(value) for value in left + right),
                'Logits contain nonnumeric, Boolean or nonfinite values')
        square_error = math.fsum((a - b) ** 2 for a, b in zip(left, right, strict=True))
        square_reference = math.fsum(a * a for a in left)
        rows.append(dict(row=index, exact_values=left == right,
                         max_absolute_error=max(abs(a - b) for a, b in zip(left, right, strict=True)),
                         relative_rms_error=math.sqrt(square_error / max(square_reference, 1e-30)),
                         argmax_equal=max(range(vocabulary), key=left.__getitem__)
                         == max(range(vocabulary), key=right.__getitem__)))
    return dict(compared_values=outputs * vocabulary, rows=rows,
                exact_values=all(row['exact_values'] for row in rows),
                argmax_equal=all(row['argmax_equal'] for row in rows))


def run_case(plan, output, case, spec, historical, record):
    archive = Path(plan['current_archive'])
    reference = Path(case['archive']) / case['name']
    destination = output / case['name']
    spec_path = output / (case['name'] + '.spec.json')
    spec_path.write_text(json.dumps(spec, indent=2) + '\n')
    record.update(name=case['name'], historical_directory=str(reference),
                  historical_native_sha256=case['historical_binary_sha256'],
                  specification_sha256=digest(spec_path),
                  only_workload_change={'execution_path': 'ordinary'}, comparisons=[])
    command = [sys.executable, str(archive / 'source/run_inference.py'),
               '--spec', str(spec_path), '--bundle', str(archive / 'bundle'), '--output', str(destination)]
    record['command'] = command
    with (output / (case['name'] + '.stdout')).open('w') as stdout, \
            (output / (case['name'] + '.stderr')).open('w') as stderr:
        process = subprocess.run(command, stdout=stdout, stderr=stderr,
                                 timeout=spec['timeout_seconds'] + 20)
    record['exit_code'] = process.returncode
    run = read_json(destination / 'run.json')
    record.update(run_sha256=digest(destination / 'run.json'),
                  bundle_manifest_sha256=run.get('bundle_manifest_sha256'),
                  verified_execution=run.get('verified_execution'))
    require(process.returncode == 0 and run.get('verified_execution') is True
            and run.get('hardware_throughput_candidate') is False, f'Current execution failed: {case["name"]}')
    require(run['spec'] == spec, 'Launcher changed the archived workload beyond explicit execution_path')
    verify_historical_bundle(destination, run)
    require(digest(destination / 'bundle/cluster-inference') == plan['current_bundle_files']['cluster-inference'],
            'Executed native binary differs from the pinned current archive')
    require(len(run['reports']) == len(historical['reports']), 'Current rank count changed')
    for rank, (old, new) in enumerate(zip(historical['reports'], run['reports'], strict=True)):
        require(new['schemaVersion'] == plan['required_native_schema']
                and new['executionPath'] == 'ordinary', 'Expected schema8 ordinary report')
        identity_mismatches = [field for field in IDENTITY_FIELDS if old.get(field) != new.get(field)]
        require(not identity_mismatches, f'Historical model/input identity changed: {identity_mismatches}')
        require(len(old['runs']) == len(new['runs']) == 1, 'Expected one measured repetition')
        result_mismatches = [field for field in RESULT_FIELDS if old['runs'][0][field] != new['runs'][0][field]]
        old_logits = reference / f'rank-{rank}/logits.json'
        new_logits = destination / f'rank-{rank}/logits.json'
        comparison = compare_logits(read_json(old_logits), read_json(new_logits),
                                    spec['workload']['decode_tokens'], old['vocabularySize'])
        comparison.update(rank=rank, historical_logits_sha256=digest(old_logits),
                          current_logits_sha256=digest(new_logits),
                          token_and_schedule_fields_exact=not result_mismatches,
                          result_field_mismatches=result_mismatches,
                          generated_tokens=new['runs'][0]['generatedTokens'])
        record['comparisons'].append(comparison)
        require(comparison['exact_values'] and comparison['argmax_equal'] and not result_mismatches,
                f'Ordinary-path regression differs from archived rank{rank}: {case["name"]}')
    record['passed'] = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', nargs='?', type=Path,
                        help='New private result directory; required unless --prepare-only')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    verify_hash(INPUTS, INPUTS_SHA256)
    plan = read_json(INPUTS)
    verify_current(plan)
    references = load_references(plan)
    if args.prepare_only:
        print(json.dumps(dict(status='prepared_not_executed', cases=[entry[0]['name'] for entry in references],
                              binary_sha256=plan['current_bundle_files']['cluster-inference'],
                              input_plan_sha256=INPUTS_SHA256, source_manifest_sha256=plan['current_source_manifest_sha256'],
                              native_processes_started=0), indent=2))
        return 0
    require(args.output is not None, 'Provide a new output directory')
    output = args.output.resolve()
    require(not output.is_relative_to(REPOSITORY), 'Regression results must be outside the repository')
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    shutil.copyfile(__file__, output / Path(__file__).name)
    shutil.copyfile(INPUTS, output / INPUTS.name)
    receipt = dict(schema_version=1, started_at=now(), status='running',
                   driver_sha256=digest(__file__), input_plan_sha256=INPUTS_SHA256,
                   current_bundle_files=plan['current_bundle_files'],
                   current_source_archive=plan['current_archive'],
                   current_source_manifest_sha256=plan['current_source_manifest_sha256'],
                   historical_cases=plan['cases'], synthetic_only=True,
                   performance_qualification=False, acceptance='exact logit values and token histories', executions=[])
    def save():
        temporary = output / 'receipt.json.tmp'
        temporary.write_text(json.dumps(receipt, indent=2, allow_nan=False) + '\n')
        temporary.replace(output / 'receipt.json')
    save()
    try:
        for case, spec, historical in references:
            record = {'started_at': now()}
            receipt['executions'].append(record)
            save()
            run_case(plan, output, case, spec, historical, record)
            record['finished_at'] = now()
            save()
            print(case['name'], 'exact archived logits and tokens', flush=True)
        verify_current(plan)
        receipt['status'] = 'passed'
        receipt['passed_cases'] = len(receipt['executions'])
    except BaseException as error:
        receipt['status'] = 'failed'
        receipt['error'] = f'{type(error).__name__}: {error}'
        raise
    finally:
        receipt['finished_at'] = now()
        save()
    print('Evidence:', output / 'receipt.json', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
