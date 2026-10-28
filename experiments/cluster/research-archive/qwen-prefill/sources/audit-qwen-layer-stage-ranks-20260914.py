#!/usr/bin/env python3
"""CPU-only, archive-bound audit of the first real9B two-process stage run."""
import datetime
from decimal import Decimal
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
sys.dont_write_bytecode = True

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
RUN = ROOT / 'runs/qwen-layer-stage-ranks-20260914'
OLD = ROOT / 'runs/qwen-layer-stage-real9b-20260913'
OUTPUT = ROOT / 'qwen-layer-stage-ranks-independent-cpu-audit-20260914.json'
HELPER = ROOT / 'qwen_layer_stage_rank_audit.py'
TEST_RECEIPT = ROOT / 'qwen-layer-stage-rank-cpu-validator-tests-20260914.json'
PRIOR_REPAIR = ROOT / 'qwen-layer-stage-real9b-independent-cpu-audit-fix1-20260913.json'
POSTFLIGHT = ROOT / 'qwen-layer-stage-ranks-postflight-20260914.json'
PINS = {
    HELPER: '489a4904d6ba947b33fabd7acf840c5f524bf37835ee2f6b81afaab80e0f0c9a',
    TEST_RECEIPT: '0ee1b1e0611abe424188bca349318fe89a1eb1d9a93d114675ab54e21b412a66',
    PRIOR_REPAIR: '54d0bb7ea744b31bf98e0d1802351c8d7c5a679448b5a7b7381ecf586738598e',
    RUN / 'receipt.json': '2048b2695e729ba187ee1e9aaa0cff1a7c1a417e11f6b741f75bc98b7fc6f50a',
    OLD / 'receipt.json': '70475fa58337738705217e6ae909945555275dcf28ec4f4cdd3349e9006d53bd',
}


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024**2), b''): value.update(block)
    return value.hexdigest()


def require(ok, message):
    if not ok: raise ValueError(message)


def read(path):
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate archived JSON key')
            result[key] = value
        return result
    require(path.stat().st_size <= 32 * 1024**2, 'Oversized archived JSON')
    return json.loads(path.read_text(), object_pairs_hook=unique,
        parse_constant=lambda _: require(False, 'Nonfinite archived JSON'))


def files(base, entries):
    require(len(entries) == len({x['path'] for x in entries}), 'Duplicate pinned path')
    for item in entries:
        relative = Path(item['path'])
        require(not relative.is_absolute() and '..' not in relative.parts, 'Unsafe archived relative path')
        path = base / relative
        require(not path.is_symlink() and path.stat().st_size == item['size_bytes']
            and sha(path) == item['sha256'], 'Archived file differs: ' + str(path))
    return entries


def main():
    require(not OUTPUT.exists(), 'Preserve previous independent audit')
    for path, pin in PINS.items(): require(sha(path) == pin, 'Pinned audit input changed: ' + str(path))
    tests = read(TEST_RECEIPT)
    require(tests['status'] == 'passed' and tests['exitCode'] == 0 and tests['testsPassed'] == 37
        and tests['helperSHA256'] == PINS[HELPER] and sha(Path(tests['testPath'])) == tests['testSHA256'], 'CPU test receipt differs')
    spec = importlib.util.spec_from_file_location('frozen_rank_audit', HELPER)
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    receipt = read(RUN / 'receipt.json'); prior = read(OLD / 'receipt.json'); repair = read(PRIOR_REPAIR)
    cohort = receipt['cohort']
    require(receipt['kind'] == 'qwen_layer_stage_rank_launcher' and receipt['schema_version'] == 1
        and receipt['passed'] is True and receipt['native_execution_attempted'] is True
        and receipt['physical_two_machine_execution'] is False and receipt['throughput_qualification'] is False
        and receipt['baseline_comparison_performed_by_launcher'] is False
        and receipt['source_bundle_runtime_inputs_model_unchanged_after_run'] is True, 'Root launch completion/scope differs')
    require(cohort['passed'] is True and cohort['exit_codes'] == [0, 0] and cohort['supervisors_reaped'] is True
        and cohort['error'] is None and cohort['cancellation_reason'] is None
        and len(cohort['supervisor_pids']) == len(set(cohort['supervisor_pids'])) == 2, 'Cohort completion differs')
    require(cohort['validation'] == dict(baseline_comparison_passed=None, complete_frames_per_rank=[6, 6],
        peer_outer_identity_agreement=True, state_logit_source_oracle_not_run_by_launcher=True, terminal_records=2),
        'Root outer-validation scope differs')
    require(prior['status'] == 'failed' and 'Common source accounting differs' in prior['error']
        and len(prior['native_calls']) == 1 and prior['native_calls'][0]['exit_code'] == 0
        and repair['status'] == 'native_completed_and_corrected_cpu_replay_passed' and repair['nativeExitCode'] == 0
        and repair['preservedFailedDriverReceiptSHA256'] == PINS[OLD / 'receipt.json'], 'Prior native/oracle correction history differs')
    require(sha(RUN / 'source-manifest.json') == receipt['source_manifest_sha256'], 'New source manifest differs')
    source = read(RUN / 'source-manifest.json'); source_files = files(RUN / 'source', source['files'])
    require(len(source_files) == receipt['source_file_count'] == 156, 'New source count differs')
    require(sha(OLD / 'source-manifest.json') == prior['source_manifest_sha256'] == repair['originalSourceManifestSHA256'],
        'Baseline source manifest differs')
    prior_source_files = files(OLD / 'source', read(OLD / 'source-manifest.json'))
    require(len(prior_source_files) == 194, 'Baseline source count differs')
    bundle_files, prior_bundle_files = [], []
    for directory, launch, target in [(RUN, receipt, bundle_files), (OLD, prior, prior_bundle_files)]:
        require(sha(directory / 'bundle/bundle.json') == launch['bundle_manifest_sha256'], 'Bundle manifest differs')
        target.extend(files(directory / 'bundle', read(directory / 'bundle/bundle.json')['files']))
    binary = next(x['sha256'] for x in bundle_files if x['path'] == 'cluster-inference')
    prior_binary = next(x['sha256'] for x in prior_bundle_files if x['path'] == 'cluster-inference')
    require(binary == 'db9c98e36cc0e2a9f4bf17cc2763ec670161bf0868311767b27325b70a3776f0'
        and prior_binary == repair['nativeBinarySHA256'] == '959d409aef53165ba05f82119f09c830d3e22d94c764e218f332b4382d16e958',
        'Native executable identity differs')
    launcher_files = files(RUN / 'launcher', receipt['launcher_files'])
    rank_files = files(RUN, receipt['rank_files']); input_files = files(RUN, receipt['inputs']['files'])
    require((len(bundle_files), len(prior_bundle_files), len(launcher_files), len(rank_files), len(input_files)) == (5, 5, 7, 12, 8),
        'Pinned archive inventory count differs')
    expected_path = RUN / 'inputs/expected-inventory.json'; expected = read(expected_path)
    require(sha(expected_path) == tests['expectedMetadataSHA256'] == 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99',
        'Independent inventory file differs')
    for archive, original in [('model-config.json', 'config.json'), ('model-manifest.json', 'manifest.json')]:
        require(sha(RUN / archive) == receipt['model_metadata_sha256'][original], 'Archived model metadata differs')
    require(receipt['configuration_sha256'] == expected['configurationSHA256'] == sha(RUN / 'model-config.json'), 'Configuration pin differs')
    aggregate = expected['artifactAggregateSHA256ClaimedByPinnedManifest']
    require(all(receipt[key] == aggregate for key in ['artifact_aggregate_sha256', 'model_before_aggregate_sha256',
        'model_after_aggregate_sha256']) and prior['model_before_aggregate_sha256'] == aggregate,
        'Root full-artifact pre/post attestations differ')
    epoch = receipt['epoch']; paths = [RUN / f'rank-{rank}/stdout.jsonl' for rank in range(2)]
    summary = helper.validate(paths, OLD / 'native/stdout.txt', epoch, expected)
    rows = [helper.read_rows(path)[0] for path in paths]
    baseline_rows, baseline_sha = helper.read_rows(OLD / 'native/stdout.txt')
    prompt = baseline_rows[0]['baseline']['request']['promptTokenIDs']
    teacher = baseline_rows[0]['baseline']['request']['teacherTokenIDs']
    require(receipt['inputs']['prompt'] == prompt and receipt['inputs']['teacher'] == teacher
        and read(RUN / 'inputs/prompt.json') == prompt and read(RUN / 'inputs/teacher.json') == teacher,
        'Saved coordinator inputs differ from original baseline')
    arguments = ['--mode', 'qwen-layer-stage-rank-check', '--model-dir', '@model', '--artifact-aggregate-sha256', aggregate,
        '--transport', 'loopback-test', '--epoch', epoch, '--execution-path', 'cbv2-contiguous',
        '--tokens-file', '@rank/prompt.json', '--teacher-tokens-file', '@rank/teacher.json',
        '--prompt-tokens', '65', '--chunk-size', '32', '--decode-tokens', '4', '--repeats', '1', '--warmups', '0', '--timeout-seconds', '180']
    for rank in range(2):
        directory = RUN / f'rank-{rank}'; config = read(directory / 'rank.json')
        helper.exact(config, dict(arguments=arguments, artifact_aggregate_sha256=aggregate, bundle=str(RUN / 'bundle'),
            bundle_sha256=receipt['bundle_manifest_sha256'], environment={'DARKBLOOM_BF16_WEIGHTS': '1', 'MLX_RANK': str(rank)},
            environment_files={'MLX_HOSTFILE': 'hosts.json'}, input_files={'hosts.json': receipt['hostfile'], 'prompt.json': prompt, 'teacher.json': teacher},
            model_directory=receipt['model_directory'], persistent=False, rank=rank, timeout_seconds=180), 'Exact native rank configuration')
        require(sha(directory / 'rank.json') == receipt['rank_configuration_sha256'][rank]
            and read(directory / 'prompt.json') == prompt and read(directory / 'teacher.json') == teacher
            and read(directory / 'hosts.json') == receipt['hostfile'], 'Rank input/configuration identity differs')
        require((directory / 'stderr.log').read_text() == 'Using loopback-test transport for correctness only; timings are not cluster-performance evidence\n',
            'Unexpected native stderr')
    require(len(receipt['hostfile']) == 2 and all(len(row) == 1 and re.fullmatch(r'127\.0\.0\.1:\d+', row[0])
        for row in receipt['hostfile']) and receipt['hostfile'][0] != receipt['hostfile'][1], 'Not two distinct loopback endpoints')
    old_map, new_map = ({x['path']: x for x in entries} for entries in [prior_source_files, source_files])
    common = set(old_map) & set(new_map)
    changed = sorted(path for path in common if old_map[path]['sha256'] != new_map[path]['sha256'])
    prefix = 'experiments/cluster/inference/Sources/ClusterInference/'
    require(changed == sorted(prefix + name for name in ['Collective.swift', 'Main.swift', 'Options.swift']),
        'Unexpected common source change from reference computation')
    compute = sorted(path for path in common if path.startswith(prefix) and path not in changed)
    require(all(old_map[path]['sha256'] == new_map[path]['sha256'] for path in compute)
        and prefix + 'QwenLayerStageSession.swift' in compute and prefix + 'VerifiedQwenLayerStageLoading.swift' in compute,
        'Shared stage computation differs')
    dependency_heads = {}
    for line in source['dependencies']['submodules'].splitlines():
        match = re.match(r'^\s*([0-9a-f]{40})\s+(\S+)\s', line)
        require(match is not None, 'Dependency submodule identity malformed')
        dependency_heads[match[2]] = match[1]
    require(source['dependencies']['tracked_dependency_changes'] == '' and all(
        old['status'] == '' and dependency_heads.get(path) == old['head'] for path, old in prior['dependencies'].items()),
        'Prior/new MLX dependency revisions or tracked-clean attestations differ')
    samples = receipt['memory_samples']; require(len(samples) == 10, 'Saved resource sample count differs')
    start_swap = Decimal(samples[0]['swap_used_bytes'])
    for index, sample in enumerate(samples):
        raw = re.fullmatch(r'([0-9]+)\ntotal = ([0-9.]+)M  used = ([0-9.]+)M  free = ([0-9.]+)M  \(encrypted\)\n', sample['raw_sysctl'])
        require(raw and int(raw[1]) == sample['pressure_level'] <= 2
            and Decimal(raw[3]) * 1024**2 == Decimal(sample['swap_used_bytes']) == start_swap,
            'Saved pressure/swap sample disagrees or changed')
        if index: require(sample['monotonic_seconds'] >= samples[index - 1]['monotonic_seconds'], 'Resource timestamps regressed')
    preflight = receipt['preflight']; vm = preflight['vm_stat']
    page_size = int(re.search(r'page size of (\d+) bytes', vm)[1])
    pages = sum(int(re.search(r'Pages ' + name + r':\s+(\d+)\.', vm)[1]) for name in ['free', 'inactive', 'speculative'])
    require(preflight['passed'] is True and preflight['estimated_reclaimable_bytes'] == page_size * pages
        and preflight['estimated_reclaimable_bytes'] >= preflight['required_reclaimable_bytes'] == 8 * 1024**3
        and preflight['disk_free_bytes'] >= preflight['required_disk_free_bytes'] == 4 * 1024**3
        and preflight['estimate_is_not_memory_guarantee'] is True, 'Saved preflight differs')
    postflight_sha = sha(POSTFLIGHT); postflight = read(POSTFLIGHT)
    require(postflight['passed'] is True and postflight['sourceReceiptSHA256'] == PINS[RUN / 'receipt.json']
        and postflight['ownedLiveProcesses'] == [] and postflight['supervisorsReaped'] is True
        and postflight['sourceCount'] == 156 and postflight['memorySamples'] == 10
        and postflight['rssSampling'] == 'Post-hoc observer began after native completion; no native RSS measurement was captured',
        'Root saved postflight differs')
    helper.exact(postflight['nativeMemory'], [row[1]['memory'] for row in rows], 'Postflight/native memory evidence')
    result = dict(schemaVersion=1, status='passed', cpuOnly=True, auditedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        auditScriptSHA256=sha(Path(__file__)), originalRunDirectory=str(RUN), originalLauncherReceiptSHA256=PINS[RUN / 'receipt.json'],
        helperSHA256=PINS[HELPER], cpuTestReceiptSHA256=PINS[TEST_RECEIPT], cpuTestsPassed=37, cpuTestSHA256=tests['testSHA256'],
        nativeExitCodes=[0, 0], testedBinarySHA256=binary, sourceManifestSHA256=receipt['source_manifest_sha256'],
        bundleManifestSHA256=receipt['bundle_manifest_sha256'], sourceFilesVerified=source_files, bundleFilesVerified=bundle_files,
        launcherFilesVerified=launcher_files, rankFilesVerified=rank_files, inputFilesVerified=input_files,
        independentPairValidation=summary, nativeArgvAndRankInputsVerified=True,
        priorBaseline=dict(nativeExitCode=0, binarySHA256=prior_binary, stdoutSHA256=baseline_sha,
            originalReceiptSHA256=PINS[OLD / 'receipt.json'], originalDriverStatus='failed',
            originalDriverError='Common source accounting differs: old CPU oracle confused 927 retained tensors with 1291 raw headers.',
            correctedIndependentAuditSHA256=PINS[PRIOR_REPAIR], correctedIndependentAuditStatus=repair['status'],
            sourceManifestSHA256=prior['source_manifest_sha256'], bundleManifestSHA256=prior['bundle_manifest_sha256'],
            sourceFilesVerified=prior_source_files, bundleFilesVerified=prior_bundle_files),
        priorComputeBinding=dict(commonUnchangedComputeFiles=compute, commonChangedFiles=changed,
            changeReview='Collective gains point-to-point methods; Main and Options add distinct rank/transport orchestration branches. Existing model, loader, state and numerical operations are unchanged.',
            additionalArchivedFiles=sorted(set(new_map) - set(old_map)), priorFilesOutsideNewSnapshot=sorted(set(old_map) - set(new_map)),
            priorMLXDependencyHeadsMatch=True, newDependencyAttestation=source['dependencies']),
        rootFullArtifactAttestations=dict(aggregateSHA256=aggregate, beforeEqualsAfter=True,
            receiptSHA256=PINS[RUN / 'receipt.json'], payloadIndependentlyRehashedByThisAudit=False),
        resources=dict(savedSamples=len(samples), pressureLevels=sorted({sample['pressure_level'] for sample in samples}),
            reportedSwapBytes=str(start_swap), newReportedSwapBytes='0', preflightEstimateRecomputed=True,
            nativeMLXMemory=[row[1]['memory'] for row in rows],
            nativeMLXPeakBytesPerRank=[row[1]['memory'][-1]['peakMLXBytesSinceProcessStart'] for row in rows],
            nativeRSSMeasurementAvailable=False, peakObservedOwnedRSSBytes=None),
        savedRootPostflight=dict(path=str(POSTFLIGHT), sha256=postflight_sha, noOwnedLiveProcesses=True,
            supervisorsReaped=True, independentPIDInventoryPerformedByThisAudit=False),
        nativeExecutionsByAudit=0, modelPayloadBytesRead=0,
        limitations=['This is two local loopback processes and one fixed real9B request, with no throughput, Thunderbolt or RDMA qualification.',
            '432 state metadata/digest entries match the prior baseline. Raw state tensors, boundary payloads and actual ACK bytes were not persisted for independent CPU reconstruction.',
            'Four full 248320-value BF16 output rows were reconstructed preserving signed zeros and compared byte-for-byte with the independently validated frozen baseline.',
            'Native retirement, weak model release and ACK completion remain source-bound native assertions. The separate root postflight reports no owned live processes.',
            'Full artifact pre/post equality and tracked-clean dependency identities are bound to root attestations; this CPU audit did not reread model payloads or reproduce a build.',
            'The RSS observer missed native execution. Native MLX peaks are available, but no process RSS peak is claimed.'])
    for path, pin in PINS.items(): require(sha(path) == pin, 'Pinned input changed during audit')
    require(sha(POSTFLIGHT) == postflight_sha, 'Saved postflight changed during audit')
    with OUTPUT.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status='passed', output=str(OUTPUT), receiptSHA256=sha(OUTPUT),
        scriptSHA256=sha(Path(__file__)), sourceFiles=len(source_files), priorSourceFiles=len(prior_source_files),
        frames=6, stateEntries=432, nativeLogitValuesPerSide=993280,
        nativeMLXPeakBytesPerRank=result['resources']['nativeMLXPeakBytesPerRank']), sort_keys=True))


if __name__ == '__main__': main()
