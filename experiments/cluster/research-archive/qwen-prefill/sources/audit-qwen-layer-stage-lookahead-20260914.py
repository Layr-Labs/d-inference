#!/usr/bin/env python3
"""Independent CPU numerical/action audit plus archived provenance for lookahead."""
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
RUN = ROOT / 'runs/qwen-layer-stage-lookahead-retry1-20260914'
BASE = ROOT / 'runs/qwen-layer-stage-real9b-20260913'
OUT = ROOT / 'qwen-layer-stage-lookahead-independent-cpu-audit-20260914.json'
HELPER = ROOT / 'qwen_layer_stage_lookahead_audit.py'
TESTS = ROOT / 'qwen-layer-stage-lookahead-cpu-validator-tests-20260914.json'
POST = ROOT / 'qwen-layer-stage-lookahead-retry1-postflight-20260914.json'
BINARY = '4cb6a17d507dbab076d83a73708373e02cc16be9f244ade251ae63cbc60f81a2'
PINS = {
    RUN / 'receipt.json': '2979510c083f23963cedabce62cec962d65543d316c02c9e016491813bff7cdb',
    BASE / 'receipt.json': '70475fa58337738705217e6ae909945555275dcf28ec4f4cdd3349e9006d53bd',
    ROOT / 'qwen-layer-stage-real9b-independent-cpu-audit-fix1-20260913.json': '54d0bb7ea744b31bf98e0d1802351c8d7c5a679448b5a7b7381ecf586738598e',
    ROOT / 'audit-qwen-layer-stage-ranks-20260914.py': 'edcffd2d35f9ab95e16ffac72da45dc7a69150c99f4bed47b821bd848921c83e',
    HELPER: '821e5199032d2721d8598232502a5acd29b3c10253634c8f6a991be9949ce76e', TESTS: '528ff2d8d0bb49cf89be0f48c20cbc0b3b12a0aea42b4c65e95b3a662739f474',
}


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def require(ok, message):
    if not ok: raise ValueError(message)


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


def main():
    require(not OUT.exists(), 'Preserve previous CPU audit')
    for path, pin in PINS.items(): require(digest(path) == pin, 'Pinned input differs: ' + path.name)
    # Reuse only the frozen prior script's pure file/JSON helpers; never run its main.
    archive = module('prior_root_archive_helpers', ROOT / 'audit-qwen-layer-stage-ranks-20260914.py')
    read, files = archive.read, archive.files
    oracle = module('frozen_lookahead_oracle', HELPER)
    rank_oracle = oracle.rank_helper()
    exact = rank_oracle.exact
    launch, old, tests = read(RUN / 'receipt.json'), read(BASE / 'receipt.json'), read(TESTS)
    require(tests['status'] == 'passed' and tests['exitCode'] == 0
        and tests['helperSHA256'] == PINS[HELPER] and digest(Path(tests['testPath'])) == tests['testSHA256'],
        'Frozen CPU test receipt differs')
    require(launch['kind'] == 'qwen_layer_stage_lookahead_launcher' and launch['passed'] is True
        and launch['native_execution_attempted'] is True and launch['flow'] == 'prompt_lookahead_one_v1'
        and launch['envelope_version'] == 2 and launch['physical_two_machine_execution'] is False
        and launch['throughput_qualification'] is False and launch['baseline_comparison_performed_by_launcher'] is False
        and launch['full_action_trace_audited_by_launcher'] is False
        and launch['source_bundle_runtime_inputs_model_unchanged_after_run'] is True, 'Native outer result/scope differs')
    cohort = launch['cohort']
    require(cohort['passed'] is True and cohort['exit_codes'] == [0, 0] and cohort['supervisors_reaped'] is True
        and cohort['error'] is None and cohort['cancellation_reason'] is None, 'Cohort completion differs')
    exact(cohort['validation'], dict(baseline_comparison_passed=None, complete_frames_per_rank=[6, 6],
        envelope_version=2, flow='prompt_lookahead_one_v1', full_action_trace_oracle_not_run_by_launcher=True,
        peer_outer_identity_agreement=True, peer_v2_header_digest_agreement=True,
        state_logit_source_oracle_not_run_by_launcher=True, terminal_records=2), 'Launcher scope')
    require(digest(RUN / 'source-manifest.json') == launch['source_manifest_sha256'], 'Source manifest differs')
    source = read(RUN / 'source-manifest.json')
    sources = files(RUN / 'source', source['files'])
    require(len(sources) == launch['source_file_count'] == 173, 'Source count differs')
    require(digest(BASE / 'source-manifest.json') == old['source_manifest_sha256'], 'Baseline source manifest differs')
    old_sources = files(BASE / 'source', read(BASE / 'source-manifest.json'))
    require(len(old_sources) == 194, 'Baseline source count differs')
    bundles = []
    for directory, receipt in [(RUN, launch), (BASE, old)]:
        require(digest(directory / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest differs')
        bundles.append(files(directory / 'bundle', read(directory / 'bundle/bundle.json')['files']))
    require(next(x['sha256'] for x in bundles[0] if x['path'] == 'cluster-inference') == BINARY, 'Native binary differs')
    launcher_files = files(RUN / 'launcher', launch['launcher_files'])
    rank_files, input_files = files(RUN, launch['rank_files']), files(RUN, launch['inputs']['files'])
    require([len(x) for x in [*bundles, launcher_files, rank_files, input_files]] == [5, 5, 8, 12, 8],
        'Archive file counts differ')
    expected_path = RUN / 'inputs/expected-inventory.json'
    require(digest(expected_path) == 'da869c797a5f37c264e4f1e1ddcf5c5f021630a9aae672dc2d2fb55ecd967a99', 'Independent inventory differs')
    expected = read(expected_path)
    aggregate = expected['artifactAggregateSHA256ClaimedByPinnedManifest']
    require(all(launch[key] == aggregate for key in ['artifact_aggregate_sha256', 'model_before_aggregate_sha256',
        'model_after_aggregate_sha256']) and old['model_before_aggregate_sha256'] == aggregate, 'Artifact attestations differ')
    for name in ['config.json', 'manifest.json']:
        require(digest(RUN / ('model-' + name)) == launch['model_metadata_sha256'][name], 'Model metadata differs')
    require(digest(RUN / 'model-config.json') == expected['configurationSHA256'] == launch['configuration_sha256'],
        'Configuration differs')
    epoch = launch['epoch']
    paths = [RUN / f'rank-{index}/stdout.jsonl' for index in range(2)]
    comparison = oracle.validate(paths, BASE / 'native/stdout.txt', epoch, expected)
    rows = [rank_oracle.read_rows(path)[0] for path in paths]
    request = rows[0][1]['request']; prompt, teacher = request['promptTokenIDs'], request['teacherTokenIDs']
    require(launch['inputs']['prompt'] == prompt and launch['inputs']['teacher'] == teacher, 'Archived input history differs')
    args = ['--mode', 'qwen-layer-stage-lookahead-check', '--model-dir', '@model', '--artifact-aggregate-sha256', aggregate,
        '--transport', 'loopback-test', '--epoch', epoch, '--execution-path', 'cbv2-contiguous', '--tokens-file', '@rank/prompt.json',
        '--teacher-tokens-file', '@rank/teacher.json', '--prompt-tokens', '65', '--chunk-size', '32', '--decode-tokens', '4',
        '--repeats', '1', '--warmups', '0', '--timeout-seconds', '180']
    for index in range(2):
        directory = RUN / f'rank-{index}'
        config = read(directory / 'rank.json')
        exact(config, dict(arguments=args, artifact_aggregate_sha256=aggregate, bundle=str(RUN / 'bundle'),
            bundle_sha256=launch['bundle_manifest_sha256'], environment={'MLX_RANK': str(index), 'DARKBLOOM_BF16_WEIGHTS': '1'},
            environment_files={'MLX_HOSTFILE': 'hosts.json'}, input_files={'hosts.json': launch['hostfile'], 'prompt.json': prompt, 'teacher.json': teacher},
            model_directory=launch['model_directory'], persistent=False, rank=index, timeout_seconds=180), 'Native configuration')
        require(digest(directory / 'rank.json') == launch['rank_configuration_sha256'][index], 'Native configuration hash differs')
        for name, value in [('hosts.json', launch['hostfile']), ('prompt.json', prompt), ('teacher.json', teacher)]:
            require(read(directory / name) == value, 'Rank input differs')
        require((directory / 'stderr.log').read_text() == 'Using loopback-test transport for correctness only; timings are not cluster-performance evidence\n',
            'Unexpected native stderr')
    require(len(launch['hostfile']) == 2 and launch['hostfile'][0] != launch['hostfile'][1]
        and all(len(row) == 1 and re.fullmatch(r'127\.0\.0\.1:\d+', row[0]) for row in launch['hostfile']), 'Loopback identity differs')
    old_map, new_map = ({item['path']: item for item in items} for items in [old_sources, sources])
    common = set(old_map) & set(new_map)
    changed = sorted(path for path in common if old_map[path]['sha256'] != new_map[path]['sha256'])
    prefix = 'experiments/cluster/inference/Sources/ClusterInference/'
    require(changed == sorted(prefix + name for name in ['Collective.swift', 'Main.swift', 'Options.swift']), 'Common compute source changed')
    heads = {}
    for line in source['dependencies']['submodules'].splitlines():
        match = re.match(r'^\s*([0-9a-f]{40})\s+(\S+)\s', line)
        require(match is not None, 'Dependency revision format differs'); heads[match[2]] = match[1]
    require(source['dependencies']['tracked_dependency_changes'] == '' and all(
        dep['status'] == '' and heads.get(path) == dep['head'] for path, dep in old['dependencies'].items()), 'Dependency attestations differ')
    samples = launch['memory_samples']; start_swap = Decimal(samples[0]['swap_used_bytes'])
    require(len(samples) == 13, 'Resource sample count differs')
    for index, sample in enumerate(samples):
        raw = re.fullmatch(r'([0-9]+)\ntotal = ([0-9.]+)M  used = ([0-9.]+)M  free = ([0-9.]+)M  \(encrypted\)\n', sample['raw_sysctl'])
        require(raw and int(raw[1]) == sample['pressure_level'] <= 2 and Decimal(raw[3]) * 1024**2
            == Decimal(sample['swap_used_bytes']) == start_swap, 'Resource sample differs or swap increased')
        if index: require(sample['monotonic_seconds'] >= samples[index - 1]['monotonic_seconds'], 'Resource time regressed')
    preflight = launch['preflight']; vm = preflight['vm_stat']
    page_size = int(re.search(r'page size of (\d+) bytes', vm)[1])
    pages = sum(int(re.search(r'Pages ' + name + r':\s+(\d+)\.', vm)[1]) for name in ['free', 'inactive', 'speculative'])
    require(preflight['passed'] is True and preflight['estimated_reclaimable_bytes'] == page_size * pages
        and preflight['estimated_reclaimable_bytes'] >= preflight['required_reclaimable_bytes'] == 8 * 1024**3
        and preflight['disk_free_bytes'] >= preflight['required_disk_free_bytes'] == 4 * 1024**3, 'Resource admission differs')
    post, post_sha = read(POST), digest(POST)
    observer_path = Path(post['processObserverPath']); observer = read(observer_path)
    require(post['passed'] is True and post['sourceReceiptSHA256'] == PINS[RUN / 'receipt.json']
        and post['ownedLiveProcesses'] == [] and post['supervisorsReaped'] is True and post['supervisorExitCodes'] == [0, 0]
        and post['sourceCount'] == 173 and post['memorySamples'] == 13 and post['nativeActionCounts'] == [73, 85]
        and post['nativePromptLookaheadCount'] == 2 and post['nativeRSSMeasurementAvailable'] is True,
        'Saved independent postflight differs')
    exact(post['nativeMemory'], [row[1]['memory'] for row in rows], 'Native memory evidence')
    require(digest(observer_path) == post['processObserverSHA256'] and observer['nativeRSSMeasurementAvailable'] is True
        and len(observer['observedNativePIDs']) == 2 and observer['terminatedOnLauncherFinalReceipt'] is True,
        'Process observer differs')
    peak = max(sum(p['rssBytes'] for p in sample['ownedProcesses'] if p['native']) for sample in observer['samples'])
    require(peak == observer['peakObservedSumNativeRSSBytes'] == post['peakObservedSumNativeRSSBytes'], 'Sampled RSS arithmetic differs')
    failed = ROOT / 'runs/qwen-layer-stage-lookahead-20260914/receipt.json'
    require(digest(failed) == 'fe29bb8fa222e54f88a850b449eef928e64d7c58a2e3737c91e488557bc5807e', 'Original resource-aborted run changed')
    failed_post = ROOT / 'qwen-layer-stage-lookahead-resource-abort-postflight-20260914.json'
    require(read(failed_post)['ownedLiveProcesses'] == [] and read(failed_post)['terminalNativeRecords'] == 0, 'Original abort cleanup differs')
    result = dict(schemaVersion=1, status='passed', cpuOnly=True, auditedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        auditScriptSHA256=digest(Path(__file__)), nativeBinarySHA256=BINARY, nativeExitCodes=[0, 0],
        originalRunDirectory=str(RUN), originalLauncherReceiptSHA256=PINS[RUN / 'receipt.json'], helperSHA256=PINS[HELPER],
        cpuTestReceiptSHA256=PINS[TESTS], cpuTestsPassed=tests['testsPassed'], independentPairValidation=comparison,
        sourceManifestSHA256=launch['source_manifest_sha256'], sourceFilesVerified=sources, priorSourceFilesVerified=old_sources,
        bundleFilesVerified=bundles, launcherFilesVerified=launcher_files, rankFilesVerified=rank_files, inputFilesVerified=input_files,
        priorCommonComputeFilesUnchanged=sorted(common - set(changed)), priorCommonChangedFiles=changed,
        dependencyAttestationsMatch=True, nativeArgumentsAndInputsVerified=True,
        rootFullArtifactBeforeAfterAttestationsMatch=True, modelPayloadIndependentlyRehashedByAudit=False,
        resources=dict(savedSamples=13, pressureLevels=[2], reportedSwapBytes=str(start_swap), additionalReportedSwapBytes='0',
            nativeMLXMemory=post['nativeMemory'], peakObservedSumNativeRSSBytes=peak, rssIsSampledNotTruePeak=True),
        savedPostflightSHA256=post_sha, savedObserverSHA256=post['processObserverSHA256'], savedNoOwnedLiveProcesses=True,
        originalResourceAbortPreservedSHA256=digest(failed), originalResourceAbortPostflightSHA256=digest(failed_post),
        nativeExecutionsByAudit=0, modelPayloadReadsByAudit=0, throughputQualified=False, physicalTransferQualified=False,
        limitations=comparison['limitations'] + ['Full artifact verification and native/PID cleanup are bound to separately saved root receipts, not rerun by this CPU audit.',
            'The earlier attempt aborted on 118MiB of new reported swap, had no terminal native evidence and is not counted as a correctness pass.'])
    for path, pin in PINS.items(): require(digest(path) == pin, 'Input changed during audit')
    require(digest(POST) == post_sha, 'Postflight changed during audit')
    with OUT.open('x') as output: json.dump(result, output, indent=2, sort_keys=True, allow_nan=False); output.write('\n')
    print(json.dumps(dict(status='passed', output=str(OUT), sha256=digest(OUT), sourceCount=len(sources),
        testsPassed=tests['testsPassed'], states=432, logitValuesPerSide=993280, actions=[73, 85], sampledCombinedRSSBytes=peak)))


if __name__ == '__main__': main()
