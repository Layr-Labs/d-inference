#!/usr/bin/env python3
"""One root-owned native tiny8 stage check, with frozen sources and process supervision."""
import argparse
import json
from pathlib import Path
import shutil
import signal
import sys
sys.dont_write_bytecode = True
from qwen9_local_tp_support import previous, preflight, bounded_launch, process_table

require, sha, read, write, now = previous.require, previous.sha, previous.read_json, previous.write_json, previous.now
HERE = Path(__file__).resolve().parent


def records(path):
    def closed(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate native JSON key')
            result[key] = value
        return result
    raw = path.read_bytes()
    require(len(raw) < 8 * 1024**2, 'Tiny stage output exceeded 8 MiB')
    return [json.loads(line, object_pairs_hook=closed,
        parse_int=lambda x: -0.0 if x == '-0' else int(x),
        parse_constant=lambda _: require(False, 'Nonfinite native JSON'))
        for line in raw.decode().splitlines() if line.lstrip().startswith('{')]


def check_fixture_records(rows):
    require(len(rows) == 6, 'Expected loader and parity records for three fixtures')
    summaries = []
    for index, (dtype, wrapped, fp16) in enumerate([
        ('float32', False, False), ('bfloat16', True, False), ('bfloat16', True, True)]):
        loader, parity = rows[index * 2:index * 2 + 2]
        require(loader['kind'] == 'qwen_layer_stage_loader_check' and
            parity['kind'] == 'qwen_layer_stage_parity_check', 'Wrong native records')
        for result in (loader, parity):
            for key, value in dict(syntheticDType=dtype, wrapped=wrapped, fp16LayerMetadata=fp16).items():
                require(type(result[key]) is type(value) and result[key] == value, 'Fixture identity differs: ' + key)
        require(loader['tensorChecks'] == loader['tensorChecksAfterSourceDeletion'] == 237,
            'Complete tensor ownership was not checked')
        require(loader['fp16MetadataTensorCount'] == (124 if fp16 else 0), 'Wrong F16 conversion inventory')
        require(sum(loader['activeTensorBytes']) == loader['sourceTensorBytes'], 'Stage bytes do not conserve source')
        require(loader['badAggregateRejectedStages'] == loader['corruptedSourceRejectedStages'] == [0, 1],
            'Both stages must reject bad source identity')
        require([len(r['activeTensors']) for r in loader['receipts']] == [118, 119], 'Wrong stage inventory')
        require(loader['receipts'][0]['storageCommitmentSHA256'] == loader['receipts'][1]['storageCommitmentSHA256'],
            'Stage storage commitments differ')
        for key in ['allActiveShapesDTypesAndBytesMatchOrdinary', 'activeNamesAndBytesConserveCanonicalSource',
            'independentCompactZeroOffsetActiveBuffersBeforeForward', 'previouslyLoadedParameterHandlesUnchangedOnRejection',
            'inactiveParametersCheckedSeparately', 'sourceFilesCorruptedAndDeleted', 'loaderProofPrecedesAnyTransformerForward']:
            require(loader[key] is True, 'Loader proof missing: ' + key)
        require(loader['modelForwardCompared'] is False, 'Loader record conflates forwarding proof')
        for key in ['correctnessOnly', 'missingResidualRejectedAndRetired', 'allRequestsRetired',
            'sourceFilesDeletedBeforeForward', 'sequentialOneProcessOnly', 'nativeBoundaryBytesCopied']:
            require(parity[key] is True, 'Parity proof missing: ' + key)
        require(parity['throughputMeasurementValid'] is False, 'Tiny sequential check cannot qualify performance')
        require(parity['promptTokenIDs'] == [3 + ((i * 17 + 7) % 509) for i in range(65)] and
            parity['teacherTokenIDs'] == [12, 25, 38],
            'Actual input history differs')
        frames = parity['frames']
        require([f['committedTokens'] for f in frames] == [32, 64, 65, 66, 67, 68], 'Frame frontiers differ')
        require([f['phase'] for f in frames] == ['prefill'] * 3 + ['decode'] * 3, 'Frame phases differ')
        for frame_index, frame in enumerate(frames):
            require(frame['stateEntriesCompared'] == 18 and frame['stateBytesCompared'] > 0 and
                frame['stateShapesDTypesAndBytesExact'] is True, 'Complete remapped state was not byte exact')
            if frame_index >= 2:
                require(frame['logitsBytesExact'] is True and frame['logits']['shape'] == [1, 512],
                    'Full logit row was not byte exact')
            else:
                require(frame.get('logits') is None and frame.get('logitsBytesExact') is None,
                    'Evaluation-only chunk claimed a logit row')
        for key, native_key in [('artifactAggregateSHA256', 'verifiedAggregateSHA256'),
            ('sourceConfigurationSHA256', 'sourceConfigurationSHA256'), ('planSHA256', 'planSHA256')]:
            require(all(parity[key] == r[native_key] for r in loader['receipts']), 'Loader/session identity differs')
        summaries.append(dict(dtype=dtype, wrapped=wrapped, fp16_layer_metadata=fp16,
            active_tensors=237, frames=6, exact_logit_rows=4, exact_state_entries=108,
            source_bytes=loader['sourceTensorBytes'], active_bytes=loader['activeTensorBytes']))
    return summaries


def check_lifecycle_records(rows):
    require(len(rows) == 9, 'Expected loader, parity and lifecycle records for three fixtures')
    initial, recovery = [], []
    for index in range(3):
        loader, parity, lifecycle = rows[index * 3:index * 3 + 3]
        require(lifecycle['kind'] == 'qwen_layer_stage_lifecycle_check' and
            lifecycle['correctnessOnly'] is True and lifecycle['throughputMeasurementValid'] is False,
            'Wrong lifecycle evidence scope')
        require(lifecycle['failedStageFrontiers'] == [32, 0] and
            lifecycle['faultInjectedAfterFirstStageCommit'] is True and
            lifecycle['bothRequestsFailedAndRetired'] is True and lifecycle['retiredRequestReuseRejected'] == 2,
            'Faulted stage pair did not retire both frontiers and reject reuse')
        recovered = lifecycle['recoveryOnSameResidentModels']
        require(recovered == parity, 'Fresh request after failure changed deterministic parity results')
        initial.extend([loader, parity]); recovery.extend([loader, recovered])
    summaries = check_fixture_records(initial)
    require(check_fixture_records(recovery) == summaries, 'Recovery validation differs')
    for result in summaries:
        result['fault_after_first_stage_commit_checked'] = True
        result['fresh_request_after_failure_exact'] = True
    return summaries


def check_records(rows):
    require(len(rows) == 11, 'Expected nine lifecycle records plus the two recording/release smoke records')
    summaries = check_lifecycle_records(rows[:9])
    checkpoint, report = rows[9:]
    require(checkpoint['kind'] == 'qwen_layer_stage_baseline_checkpoint' and
        report['kind'] == 'qwen_layer_stage_comparison_report', 'Wrong recording smoke records')
    require(checkpoint['baselineModelReleasedBeforeStageLoading'] is True and
        report['baselineModelReleasedBeforeStageLoading'] is True and
        report['stageModelsReleasedAfterComparison'] is True, 'Model release proof missing')
    baseline, comparison = checkpoint['baseline'], report['comparison']
    require(baseline['allRequestStateRetired'] is True and comparison['allRequestStateRetired'] is True,
        'Recorded request state was not retired')
    require(baseline['source'] == comparison['source'] and
        comparison['baselineEvidenceSHA256'] == baseline['fingerprint'] and
        comparison['requestSHA256'] == baseline['request']['fingerprint'], 'Recorded identities differ')
    require(baseline['source']['layerCount'] == 8 and baseline['source']['vocabularySize'] == 512 and
        baseline['source']['embeddingActivationDType'] == 'bfloat16' and
        baseline['source']['bf16ConversionEnabled'] is True, 'Recording fixture scope changed')
    require([f['committedTokens'] for f in baseline['frames']] == [32, 64, 65, 66, 67, 68] and
        len(comparison['frames']) == 6, 'Recorded timeline differs')
    for original, compared in zip(baseline['frames'], comparison['frames']):
        require(original['frame'] == compared['frame'] and original['committedTokens'] == compared['committedTokens'] and
            len(original['state']['entries']) == compared['stateEntriesCompared'] == 18 and
            original['state']['logicalByteCount'] == compared['logicalStateBytesPerSide'] and
            original['state']['fingerprint'] == compared['globalStateSHA256'] and
            compared['stateMetadataAndDigestsExact'] is True, 'Recorded state commitments differ')
        require(original.get('logits') == compared.get('logits'), 'Recorded captured logit rows differ')
        if original.get('logits') is not None:
            require(compared['nativeLogitBytesExact'] is True, 'Native recorded logit comparison missing')
    summaries.append(dict(kind='recording_release_smoke', dtype='bfloat16', fp16_layer_metadata=True,
        baseline_and_stages_separately_resident=True, frames=6, state_entries=108, exact_logit_rows=4,
        native_and_record_identity_checks=True, independent_cpu_oracle_is_separate=True))
    return summaries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--expected-native-sha256', required=True)
    args = parser.parse_args(); out = args.output.resolve()
    require(not out.exists() and not out.is_relative_to(previous.REPO), 'Output must be new and outside repo')
    require(sha(previous.RELEASE / 'cluster-inference') == args.expected_native_sha256, 'Native build differs from pin')
    require(not [p for p in process_table().values() if '/cluster-inference ' in p['command'] or '/rank_worker.py ' in p['command']],
        'Refusing concurrent native probe')
    out.mkdir(mode=0o700, parents=True)
    receipt = dict(schema_version=1, status='preparing', started_at=now(), native_calls=[],
        expected_native_sha256=args.expected_native_sha256, planned_native_calls=1,
        tiny_synthetic_only=True, physical_two_machine_execution=False, throughput_qualification=False,
        limitations=['Sequential single-process tiny8 4+4 correctness only; no target model or network qualification.',
            'Uses the unchanged conservative real9B solo resource estimate even for this much smaller fixture.',
            'RSS/headroom samples are estimates; pressure and new-swap checks are monitored abort criteria.'])
    save = lambda: write(out / 'receipt.json', receipt)
    save()
    try:
        for name in ['validate-qwen-layer-stage.py', 'qwen9_local_tp_support.py', 'validate-qwen9-output-boundaries.py']:
            shutil.copy2(HERE / name, out / name)
        receipt['driver_files_sha256'] = {p.name: sha(p) for p in out.glob('*.py')}
        sources, deps = previous.snapshot_sources(out)
        receipt.update(source_manifest_sha256=sha(out / 'source-manifest.json'), dependencies=deps)
        sys.path.insert(0, str(out / 'source/experiments/cluster'))
        from runtime.bundle import snapshot
        from runtime.artifacts import verify_files
        receipt['bundle_manifest_sha256'] = snapshot(previous.RELEASE, out / 'bundle')
        bundle = read(out / 'bundle/bundle.json')['files']
        receipt['bundle_files'] = verify_files(out / 'bundle', bundle)
        require(receipt['bundle_files']['cluster-inference'] == args.expected_native_sha256, 'Frozen native differs')
        previous.verify_sources(out, sources)
        entry = dict(preflight=preflight('solo', out)); receipt['native_calls'].append(entry)
        receipt['status'] = 'running'; save()
        require(entry['preflight']['passed'], 'Conservative resource gate refused')
        command = [str(out / 'bundle/cluster-inference'), '--mode', 'qwen-layer-stage-check', '--synthetic',
            '--execution-path', 'cbv2-contiguous', '--prompt-tokens', '65', '--chunk-size', '32', '--decode-tokens', '4',
            '--repeats', '1', '--warmups', '0', '--timeout-seconds', '170']
        bounded_launch(command, out, out / 'native', previous.environment(), entry, save, 'solo')
        receipt['fixtures'] = check_records(records(out / 'native/stdout.txt'))
        previous.verify_sources(out, sources)
        require(verify_files(out / 'bundle', bundle) == receipt['bundle_files'], 'Frozen bundle changed')
        entry['postflight'] = preflight('solo', out)
        require(not entry['postflight']['severe_pressure'] and
            entry['postflight']['swap_used_bytes'] - entry['preflight']['swap_used_bytes'] <= 1024**3,
            'Postflight pressure/swap gate failed')
        receipt.update(status='completed', finished_at=now(), native_records_sha256=sha(out / 'native/stdout.txt'))
        save(); print(json.dumps(dict(status='completed', fixtures=receipt['fixtures'], output=str(out))))
    except BaseException as error:
        receipt.update(status='failed', finished_at=now(), error=f'{type(error).__name__}: {error}')
        save(); raise


def interrupted(signum, frame):
    raise KeyboardInterrupt('Stage diagnostic interrupted by signal ' + str(signum))


if __name__ == '__main__':
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, interrupted)
    main()
