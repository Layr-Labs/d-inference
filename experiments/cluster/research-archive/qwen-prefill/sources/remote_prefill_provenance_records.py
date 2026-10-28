"""CPU-only checks of saved remote controls and resource observations."""
from datetime import datetime
from decimal import Decimal
import math
import re


def require(value, message):
    if not value:
        raise ValueError(message)


def uint(value, message):
    require(type(value) is int and value >= 0, message)
    return value


def clock_value(value):
    require(type(value) in (int, float) and math.isfinite(value) and value >= 0, 'Invalid saved monotonic value')
    # Each remote control is a separate Python process. Its monotonic epoch is
    # not established as shared with another control process on Python 3.9.


def utc(value):
    require(type(value) is str and datetime.fromisoformat(value).utcoffset() is not None,
            'Saved UTC observation has no timezone')


def vm_bytes(raw):
    require(isinstance(raw, str) and len(raw) <= 16384, 'Invalid bounded vm_stat')
    match = re.search(r'page size of (\d+) bytes', raw)
    require(match is not None and int(match[1]) > 0, 'Missing memory page size')
    counts = []
    for key in ('free', 'inactive', 'speculative'):
        matches = re.findall(r'^Pages ' + key + r':\s+(\d+)\.$', raw, re.MULTILINE)
        require(len(matches) == 1, 'Missing/duplicate vm_stat category')
        counts.append(int(matches[0]))
    return int(match[1]) * counts[0], int(match[1]) * sum(counts)


def memory_values(raw):
    require(isinstance(raw, str) and len(raw) <= 4096, 'Invalid bounded sysctl')
    lines = raw.strip().splitlines()
    require(len(lines) == 2 and re.fullmatch(r'\d+', lines[0]) is not None, 'Unexpected pressure output')
    match = re.search(r'\bused\s*=\s*([0-9]+(?:\.[0-9]+)?)([KMGT])\b', lines[1])
    require(match is not None, 'Missing reported swap usage')
    return int(lines[0]), Decimal(match[1]) * 1024 ** ('KMGT'.index(match[2]) + 1)


def validate_resources(receipt):
    initial, before = receipt['remote_initial_free_screen'], receipt['remote_before']
    free, reclaimable = vm_bytes(initial['vm_stat'])
    require(initial['phase'] == 'remote_before_bundle_staging_and_remote_artifact_hashing'
            and initial['passed'] is True and free == initial['actual_free_bytes']
            and free >= initial['required_actual_free_bytes'] == 6 * 1024**3
            and reclaimable == initial['estimated_reclaimable_bytes']
            and initial['guarantees_six_gib_free_at_native_launch'] is False, 'Initial remote free screen differs')
    utc(initial['timestamp_utc']); clock_value(initial['monotonic_seconds'])
    pre = before['posthash_preflight']
    post_free, post_reclaim = vm_bytes(pre['vm_stat'])
    require(pre['passed'] is True and pre['phase'] == 'after_artifact_hashing_before_native'
            and post_free == pre['actual_free_bytes'] and post_reclaim == pre['estimated_reclaimable_bytes']
            and post_reclaim >= pre['required_reclaimable_bytes'] == 8 * 1024**3
            and pre['disk_free_bytes'] >= pre['required_disk_free_bytes'] == 4 * 1024**3
            and pre['estimate_is_not_memory_guarantee'] is True, 'Remote posthash resource screen differs')
    utc(pre['timestamp_utc']); clock_value(pre['monotonic_seconds'])
    soft, opened = pre['nofile_soft'], uint(pre['open_descriptors'], 'Invalid descriptor count')
    require(type(soft) is int and (soft == -1 or soft >= 256 and opened + 128 < soft), 'Descriptor screen differs')
    samples, remote = receipt['remote_memory_samples'], receipt['remote_paths']
    require(samples, 'No saved remote memory samples')
    baseline = Decimal(samples[0]['swap_used_bytes'])
    native, supervisors, rss = set(), set(), []
    native_rss, supervisor_rss, observed_sums = [], [], []
    for sample in samples:
        clock_value(sample['monotonic_seconds'])
        level, swap = memory_values(sample['raw_sysctl'])
        require(type(sample['pressure_level']) is int and level == sample['pressure_level'] <= 2
                and Decimal(sample['swap_used_bytes']) == swap <= baseline and baseline.is_finite(),
                'Remote raw pressure/swap differs or increased')
        inventory = sample['remote_pid_inventory']
        require(inventory['exact_run_path_match'] is True
                and inventory['observation_is_not_waitpid_or_remote_reaping_proof'] is True
                and inventory['rss_is_sampled_not_peak'] is True
                and inventory['missing_process_rss_is_not_assumed_zero'] is True, 'PID/RSS scope differs')
        rows = inventory['observed_processes']
        require(isinstance(rows, list) and len(rows) <= 16, 'Unbounded process inventory')
        sample_native, sample_supervisor, sample_sum = [], [], []
        for row in rows:
            require(set(row) == {'kind', 'pid', 'ppid', 'pgid', 'rssBytes', 'command'}, 'Unexpected PID observation fields')
            require(uint(row['pid'], 'Invalid PID') > 0, 'Zero PID')
            uint(row['ppid'], 'Invalid PPID'); uint(row['pgid'], 'Invalid PGID')
            require(uint(row['rssBytes'], 'Invalid RSS') % 1024 == 0, 'RSS not an integer reported KiB multiple')
            command = row['command']
            require(isinstance(command, str), 'Invalid process command')
            if row['kind'] == 'native':
                binary = remote['bundle'] + '/cluster-inference'
                require(command == binary or command.startswith(binary + ' '), 'Native process belongs to another run')
                require(row['pgid'] == row['pid'], 'Native process is not its owned session-group leader')
                native.add(row['pid']); native_rss.append(row['rssBytes']); sample_native.append(row)
            else:
                require(row['kind'] == 'supervisor'
                        and remote['bundle'] + '/rank_worker.py' in command.split()
                        and remote['native'] + '/rank.json' in command.split(), 'Supervisor belongs to another run')
                supervisors.add(row['pid']); supervisor_rss.append(row['rssBytes']); sample_supervisor.append(row)
            sample_sum.append(row['rssBytes'])
        require(len({row['pid'] for row in rows}) == len(rows), 'Duplicate process sample')
        if sample_native and sample_supervisor:
            require(all(row['ppid'] in {p['pid'] for p in sample_supervisor} for row in sample_native), 'Observed native parent differs')
        if sample_sum:
            observed_sums.append(sum(sample_sum))
        rss.append(dict(nativeObserved=bool(sample_native), supervisorObserved=bool(sample_supervisor)))
    require(sorted(native) == receipt['observed_remote_native_pids']
            and sorted(supervisors) == receipt['observed_remote_supervisor_pids'], 'Saved aggregate PID lists differ')
    require(samples[-1]['remote_pid_inventory']['observed_processes'] == [], 'Remote owned process observed at final sample')
    return dict(samples=len(samples), pressureLevels=sorted({s['pressure_level'] for s in samples}),
                initialActualFreeBytes=free, posthashActualFreeBytes=post_free, posthashReclaimableBytes=post_reclaim,
                initialActualFreeRecomputed=True, posthashReclaimableRecomputed=True,
                reportedSwapBaselineBytes=str(baseline), maximumReportedSwapIncreaseBytes='0',
                observedNativePIDs=sorted(native), observedSupervisorPIDs=sorted(supervisors),
                nativeRSSObservationCount=len(native_rss), supervisorRSSObservationCount=len(supervisor_rss),
                maximumSampledNativeRSSBytes=max(native_rss, default=None),
                maximumSampledSupervisorRSSBytes=max(supervisor_rss, default=None),
                maximumSumOfObservedMatchingRSSBytes=max(observed_sums, default=None),
                samplePresence=rss, RSSUnitMultiplesChecked=True, rawPsOutputWasPersisted=False,
                rawPsRSSIndependentlyReconstructed=False, RSSIsNotPeakOrMissingEqualsZero=True,
                crossProcessMonotonicOrderingAsserted=False)


def controls_sequence(directory, receipt, read, sha):
    paths = sorted(directory.glob('*.json'))
    entries, results = [], []
    for index, path in enumerate(paths, 1):
        item = read(path); op = item['operation']
        require(path.name == '%04d-%s.json' % (index, op) and item['passed'] is True, 'Control order/status differs')
        require(type(item['timeout_seconds']) in (int, float) and 0 < item['timeout_seconds'] <= 120, 'Control timeout differs')
        record = item['record']
        require(record['kind'] == 'remote_prefill_control' and type(record['schema_version']) is int
                and record['schema_version'] == 1 and record['operation'] == op
                and record['run_id'] == receipt['run_id'] and record['remote_run'] == receipt['remote_paths']['run'],
                'Control identity differs')
        entries.append(dict(path=path.name, sha256=sha(path), operation=op))
        results.append(record['result'])
    operations = [entry['operation'] for entry in entries]
    require(len(operations) >= 3 and operations[:2] == ['initial', 'before'] and operations[-1] == 'after'
            and all(op == 'observe' for op in operations[2:-1]), 'Unexpected remote control sequence')
    require(results[0] == receipt['remote_initial_free_screen'] and results[1] == receipt['remote_before']
            and results[-1] == receipt['remote_after'], 'Control result differs from launch receipt')
    require([results[1]['memory'], *results[2:-1], results[-1]['memory']] == receipt['remote_memory_samples'],
            'Control samples differ from launch receipt')
    return entries
