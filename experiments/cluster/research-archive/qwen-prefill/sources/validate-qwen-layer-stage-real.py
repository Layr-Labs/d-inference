#!/usr/bin/env python3
"""Root-only pinned9B baseline-then-stages correctness run; no target throughput claim."""
import argparse
import json
from pathlib import Path
import shutil
import signal
import sys
sys.dont_write_bytecode = True
import qwen9_local_tp_support as supervision
from qwen9_local_tp_support import previous, bounded_launch, process_table
from qwen_layer_stage_recorded_audit import check_recorded_pair

require, sha, read, write, now = previous.require, previous.sha, previous.read_json, previous.write_json, previous.now
HERE = Path(__file__).resolve().parent
PRIOR = HERE / 'runs/qwen9-output-boundaries-20260913'
PRIOR_RECEIPT_SHA = '0afffd9b1863f785f4f3880f71c21305177f36cb825e29e506983ff0f745cfc1'
EXPECTED_SHA = 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99'
CONFIG_SHA = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
original_preflight = supervision.preflight


def preflight(partition, output):
    result = original_preflight(partition, output)
    result['prior_required_headroom_bytes'] = result['required_headroom_bytes']
    result['extra_diagnostic_reserve_bytes'] = 1024**3
    result['required_headroom_bytes'] += 1024**3
    result['headroom_policy'] += ' +1GiB reserve for stage placeholders, boundary/state snapshots and retained/encoded full-vocabulary evidence'
    result['memory_passed'] = result['estimated_reclaimable_bytes'] >= result['required_headroom_bytes']
    result['passed'] = result['memory_passed'] and result['descriptors_passed'] and result['disk_passed'] and not result['severe_pressure']
    return result


supervision.preflight = preflight


def records(path):
    def closed(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'Duplicate native JSON key'); value[key] = item
        return value
    with path.open('rb') as stream:
        raw = stream.read(64 * 1024**2 + 1)
    require(len(raw) <= 64 * 1024**2, 'Recorded native output exceeded64MiB')
    return [json.loads(line, object_pairs_hook=closed,
        parse_int=lambda x: -0.0 if x == '-0' else int(x),
        parse_constant=lambda _: require(False, 'Nonfinite native JSON'))
        for line in raw.decode().splitlines() if line.lstrip().startswith('{')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--expected-native-sha256', required=True)
    args = parser.parse_args(); out = args.output.resolve()
    require(not out.exists() and not out.is_relative_to(previous.REPO) and not out.is_relative_to(previous.MODEL),
        'Output must be new and outside repository/model')
    require(sha(previous.RELEASE / 'cluster-inference') == args.expected_native_sha256, 'Build differs from root pin')
    require(sha(HERE / 'qwen-layer-stage-real9b-expected-20260913.json') == EXPECTED_SHA, 'Independent expected inventory changed')
    require(sha(PRIOR / 'receipt.json') == PRIOR_RECEIPT_SHA, 'Input origin receipt changed')
    require(sha(previous.MODEL / 'config.json') == CONFIG_SHA, 'Registered configuration changed')
    require(not [p for p in process_table().values() if '/cluster-inference ' in p['command'] or '/rank_worker.py ' in p['command']],
        'Refusing concurrent native probe')
    out.mkdir(mode=0o700, parents=True)
    receipt = dict(schema_version=1, status='preparing', started_at=now(), native_calls=[],
        expected_native_sha256=args.expected_native_sha256, expected_artifact_aggregate_sha256=previous.AGGREGATE,
        expected_configuration_sha256=CONFIG_SHA, planned_native_calls=1,
        physical_two_machine_execution=False, throughput_qualification=False,
        limitations=['One fixed65-token text prefix and3 fixed teacher continuations, batch one, native policies.',
            'Sequential single-process correctness only; baseline model is released before loading both stages.',
            'Native logit bytes and complete state metadata/digests compare exactly; raw state bytes are not exported.',
            'Memory estimates/RSS sampling are not total process-memory guarantees.'])
    save = lambda: write(out / 'receipt.json', receipt)
    save()
    try:
        for name in ['validate-qwen-layer-stage-real.py', 'qwen_layer_stage_recorded_audit.py',
            'qwen9_local_tp_support.py', 'validate-qwen9-output-boundaries.py',
            'derive-qwen-layer-stage-real9b-expected-20260913.py', 'qwen-layer-stage-real9b-expected-20260913.json']:
            shutil.copy2(HERE / name, out / name)
        receipt['driver_files_sha256'] = {p.name: sha(p) for p in out.iterdir() if p.name != 'receipt.json'}
        sources, deps = previous.snapshot_sources(out)
        receipt.update(source_manifest_sha256=sha(out / 'source-manifest.json'), dependencies=deps)
        sys.path.insert(0, str(out / 'source/experiments/cluster'))
        from runtime.bundle import snapshot
        from runtime.artifacts import verify_model, verify_files
        receipt['bundle_manifest_sha256'] = snapshot(previous.RELEASE, out / 'bundle')
        bundle = read(out / 'bundle/bundle.json')['files']
        receipt['bundle_files'] = verify_files(out / 'bundle', bundle)
        require(receipt['bundle_files']['cluster-inference'] == args.expected_native_sha256, 'Frozen executable differs')
        expected = read(out / 'qwen-layer-stage-real9b-expected-20260913.json')
        receipt['model_before_aggregate_sha256'] = verify_model(previous.MODEL, previous.AGGREGATE)
        require(sha(previous.MODEL / 'manifest.json') == expected['manifestSHA256'] and
            sha(previous.MODEL / 'config.json') == expected['configurationSHA256'], 'Expected inventory artifact differs')
        shutil.copy2(previous.MODEL / 'manifest.json', out / 'model-manifest.json')
        prompt96 = read(PRIOR / 'prompt-96.json'); prompt = read(PRIOR / 'prompt-65.json')
        require(len(prompt) == 65 and prompt == prompt96[:65], 'Frozen65 prefix differs')
        teacher = read(PRIOR / 'cbv2-native/rank-0/teacher.json')
        require(len(teacher) == 3 and all(type(x) is int and 0 <= x < 248320 for x in prompt + teacher), 'Frozen token history differs')
        write(out / 'prompt-65.json', prompt); write(out / 'teacher-3.json', teacher)
        shutil.copy2(PRIOR / 'source-text.txt', out / 'source-text.txt')
        receipt['input_files_sha256'] = {name: sha(out / name) for name in ['prompt-65.json', 'teacher-3.json', 'source-text.txt']}
        previous.verify_sources(out, sources)
        entry = dict(preflight=preflight('solo', out)); receipt['native_calls'].append(entry)
        receipt['status'] = 'running'; save(); require(entry['preflight']['passed'], 'Resource gate refused')
        command = [str(out / 'bundle/cluster-inference'), '--mode', 'qwen-layer-stage-compare',
            '--model-dir', str(previous.MODEL), '--artifact-aggregate-sha256', previous.AGGREGATE,
            '--tokens-file', str(out / 'prompt-65.json'), '--teacher-tokens-file', str(out / 'teacher-3.json'),
            '--execution-path', 'cbv2-contiguous', '--prompt-tokens', '65', '--chunk-size', '32', '--decode-tokens', '4',
            '--repeats', '1', '--warmups', '0', '--timeout-seconds', '170']
        bounded_launch(command, out, out / 'native', previous.environment(), entry, save, 'solo')
        rows = records(out / 'native/stdout.txt'); require(len(rows) == 2, 'Expected baseline checkpoint and comparison report')
        require(rows[0]['baseline']['request']['promptTokenIDs'] == prompt and
            rows[0]['baseline']['request']['teacherTokenIDs'] == teacher, 'Native input history changed')
        receipt['cpu_evidence_check'] = check_recorded_pair(rows[0], rows[1], expected=expected)
        previous.verify_sources(out, sources)
        require(verify_files(out / 'bundle', bundle) == receipt['bundle_files'], 'Frozen bundle changed')
        receipt['model_after_aggregate_sha256'] = verify_model(previous.MODEL, previous.AGGREGATE)
        entry['postflight'] = preflight('solo', out)
        require(not entry['postflight']['severe_pressure'] and
            entry['postflight']['swap_used_bytes'] - entry['preflight']['swap_used_bytes'] <= 1024**3,
            'Postflight pressure/swap gate failed')
        receipt.update(status='completed', finished_at=now(), native_records_sha256=sha(out / 'native/stdout.txt'))
        save(); print(json.dumps(dict(status='completed', output=str(out), checks=receipt['cpu_evidence_check'])))
    except BaseException as error:
        receipt.update(status='failed', finished_at=now(), error=f'{type(error).__name__}: {error}')
        save(); raise


def interrupted(signum, frame):
    raise KeyboardInterrupt('Stage diagnostic interrupted by signal ' + str(signum))


if __name__ == '__main__':
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT): signal.signal(signum, interrupted)
    main()
