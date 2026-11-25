#!/usr/bin/env python3
"""Source/bundle-bound CPU audit of the frozen successful two-rank P2P run."""
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
RUN = ROOT / 'runs/stage-p2p-success-20260914'
HELPER = ROOT / 'stage-p2p-cpu-audit-draft.py'
TEST_RECEIPT = ROOT / 'stage-p2p-cpu-audit-draft-validation-20260914.json'
OUTPUT = ROOT / 'stage-p2p-success-independent-cpu-audit-20260914.json'
RECEIPT_SHA = 'edb311c27b1e472b6331ffd2c6080c2390e9f835d746c684dacc61d01b9bfa9d'
HELPER_SHA = '14b25ddc6e6e3165e3f47efa0f4f10e6eab5a1ef81930bbd15e49babdc577b1d'
TEST_RECEIPT_SHA = '7257c6c3d18c617fa59e79a5a50a5e57506a716de95eedad1f2956800391542f'


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024**2), b''):
            h.update(block)
    return h.hexdigest()


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read(path):
    def unique(items):
        result = {}
        for k, v in items:
            require(k not in result, 'Duplicate receipt/manifest key')
            result[k] = v
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique,
        parse_constant=lambda _: require(False, 'Nonfinite receipt/manifest'))


def files(base, entries):
    require(len(entries) == len({x['path'] for x in entries}), 'Duplicate pinned path')
    for item in entries:
        path = base / item['path']
        require(path.stat().st_size == item['size_bytes'] and sha(path) == item['sha256'], 'Pinned file changed: ' + str(path))
    return entries


def main():
    require(not OUTPUT.exists(), 'Preserve existing independent audit')
    require(sha(HELPER) == HELPER_SHA and sha(TEST_RECEIPT) == TEST_RECEIPT_SHA, 'Frozen oracle/test validation changed')
    prior = read(TEST_RECEIPT)
    require(prior['cpuTestsPassed'] == 26 and prior['testExitCode'] == 0 and prior['helperSHA256'] == HELPER_SHA,
        'Prior CPU validation identity differs')
    require(sha(Path(prior['testPath'])) == prior['testSHA256'], 'Prior CPU tests changed')
    require(sha(RUN / 'receipt.json') == RECEIPT_SHA, 'Original launcher receipt changed')
    receipt = read(RUN / 'receipt.json'); cohort = receipt['cohort']
    require(receipt['kind'] == 'stage_p2p_launcher' and receipt['scenario'] == 'success'
        and receipt['passed'] is True and receipt['native_success'] is True
        and receipt['correctness_only'] is True and receipt['no_models'] is True
        and receipt['throughput_measurement_valid'] is False, 'Launcher completion/scope differs')
    require(cohort['passed'] is True and cohort['scenario_passed'] is True and cohort['exit_codes'] == [0, 0]
        and cohort['configured_rank_count'] == cohort['started_rank_count'] == 2
        and cohort['supervisors_reaped'] is True and cohort['error'] is None and cohort['cancellation_reason'] is None
        and cohort['peer_loss_injected'] is False, 'Cohort completion differs')
    require(sha(RUN / 'source-manifest.json') == receipt['source_manifest_sha256'], 'Source manifest changed')
    source = read(RUN / 'source-manifest.json')
    source_files = files(RUN / 'source', source['files'])
    require(len(source_files) == receipt['source_file_count'] == 152, 'Archived source count differs')
    require(sha(RUN / 'bundle/bundle.json') == receipt['bundle_manifest_sha256'], 'Bundle manifest changed')
    bundle_files = files(RUN / 'bundle', read(RUN / 'bundle/bundle.json')['files'])
    native = next(x for x in bundle_files if x['path'] == 'cluster-inference')['sha256']
    require(native == '200cd84f1d2047a31fe0c75df37cd022a782d49213e86f1cca20d84d3b04cf5e', 'Tested executable differs')
    launcher_files = files(RUN / 'launcher', receipt['launcher_files'])
    rank_files = files(RUN, receipt['rank_files'])
    epoch = receipt['epoch']
    for rank in range(2):
        directory = RUN / f'rank-{rank}'
        config = read(directory / 'rank.json')
        require(sha(directory / 'rank.json') == receipt['rank_configuration_sha256'][rank]
            and config['rank'] == rank and config['persistent'] is False and config['timeout_seconds'] == 60
            and config['bundle'] == str(RUN / 'bundle') and config['bundle_sha256'] == receipt['bundle_manifest_sha256'],
            'Rank configuration identity differs')
        require(config['arguments'] == ['--mode', 'stage-p2p-check', '--synthetic', '--transport', 'loopback-test',
            '--timeout-seconds', '60', '--epoch', epoch], 'Native command arguments differ')
        require(config['environment'] == {'MLX_RANK': str(rank)} and config['environment_files'] == {'MLX_HOSTFILE': 'hosts.json'}
            and config['input_files'] == {'hosts.json': receipt['hostfile']}
            and read(directory / 'hosts.json') == receipt['hostfile'], 'Rank environment/loopback host identity differs')
        require((directory / 'stderr.log').read_text() == 'Using loopback-test transport for correctness only; timings are not cluster-performance evidence\n',
            'Unexpected native stderr')
    require(len(receipt['hostfile']) == 2 and all(len(row) == 1 and re.fullmatch(r'127\.0\.0\.1:\d+', row[0])
        for row in receipt['hostfile']) and receipt['hostfile'][0] != receipt['hostfile'][1], 'Not two distinct loopback endpoints')
    spec = importlib.util.spec_from_file_location('frozen_p2p_audit', HELPER)
    helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)
    summary = helper.check_pair([RUN / f'rank-{rank}/stdout.jsonl' for rank in range(2)], epoch)
    for rank in range(2):
        rows = [helper.strict_json(line) for line in (RUN / f'rank-{rank}/stdout.jsonl').read_bytes().splitlines()]
        helper.exact(cohort['records'][rank], rows, 'launcher retained native records')
    samples = receipt['memory_samples']
    require(samples and all(x['pressure_level'] <= 2 for x in samples), 'Severe saved pressure')
    starting_swap = Decimal(samples[0]['swap_used_bytes'])
    for sample in samples:
        swap = Decimal(sample['swap_used_bytes'])
        observed = re.search(r'used = ([0-9.]+)M', sample['raw_sysctl'])
        require(observed and Decimal(observed[1]) * 1024**2 == swap and swap == starting_swap,
            'Saved swap changed or raw/numeric mismatch')
    original_repo = Path(source['repository'])
    source_by_path = {x['path']: x for x in source_files}
    fixture_source_binding = []
    for item in prior['sourceFiles']:
        relative = str(Path(item['path']).relative_to(original_repo))
        native_source = source_by_path[relative]
        fixture_source_binding.append(dict(path=relative, priorValidatorSourceSHA256=item['sha256'],
            nativeArchivedSourceSHA256=native_source['sha256'], unchanged=item['sha256'] == native_source['sha256']))
    result = dict(schemaVersion=1, status='passed', cpuOnly=True, auditScriptSHA256=sha(Path(__file__)),
        auditedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), originalRunDirectory=str(RUN),
        originalLauncherReceiptSHA256=RECEIPT_SHA, frozenCPUHelperSHA256=HELPER_SHA,
        prior26TestValidationReceiptSHA256=TEST_RECEIPT_SHA, priorCPUTestSHA256=prior['testSHA256'],
        nativeExitCodes=[0, 0], testedBinarySHA256=native, nativeArgvAndRankConfigurationVerified=True,
        sourceManifestSHA256=receipt['source_manifest_sha256'], bundleManifestSHA256=receipt['bundle_manifest_sha256'],
        sourceFilesVerified=source_files, bundleFilesVerified=bundle_files, launcherFilesVerified=launcher_files,
        rankFilesVerified=rank_files, validatorFixtureSourceBinding=fixture_source_binding,
        sourceDependencies=source['dependencies'], independentPairValidation=summary,
        savedResourceSamples=dict(count=len(samples), pressureLevels=sorted({x['pressure_level'] for x in samples}),
            startingSwapBytes=str(starting_swap), newSwapBytes='0'),
        savedSupervisorsReaped=True, independentNativePIDInventoryPerformed=False,
        nativeExecutionsByAudit=0, modelFileReadsByAudit=0,
        limitations=['Full archived source, bundle, launcher and rank file identities are verified; source/executable association relies on the frozen root launch snapshot, not a reproduced build.',
            'Raw received payload bytes and actual ACK arrays are not exported. CPU independently regenerates exact fixture bytes and emitted hashes; actual receive-byte and ACK equality are native assertions.',
            'Root performs independent PID postflight and failure scenarios separately; this audit does not claim those checks.',
            'Loopback ring, two processes, no model forward, physical Thunderbolt/RDMA or throughput qualification.'])
    require(sha(RUN / 'receipt.json') == RECEIPT_SHA and sha(HELPER) == HELPER_SHA, 'Frozen run/oracle changed during audit')
    with OUTPUT.open('x') as stream:
        json.dump(result, stream, indent=2, sort_keys=True, allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status='passed',output=str(OUTPUT),receiptSHA256=sha(OUTPUT),auditScriptSHA256=sha(Path(__file__)),
        sourceFiles=len(source_files),bundleFiles=len(bundle_files),launcherFiles=len(launcher_files),rankFiles=len(rank_files),
        residualFramesPerRank=54,controlCasesPerRank=7,sourceContractChanges=[x['path'] for x in fixture_source_binding if not x['unchanged']]),sort_keys=True))


if __name__ == '__main__':
    main()
