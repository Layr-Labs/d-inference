"""Replay saved two-rank observations; no current process or memory reads."""
import copy
from decimal import Decimal
from long_reference_provenance_common import require
from remote_prefill_provenance_records import controls_sequence, validate_resources


def resources_and_controls(run, receipt, read, sha):
    samples = receipt['remote_memory_samples']
    require(type(samples) is list and 1 <= len(samples) <= 512, 'Missing or unbounded memory observations')
    remote = receipt['remote_paths']
    native_sets, supervisor_sets, simultaneous = [set(), set()], [set(), set()], []
    for index, sample in enumerate(samples):
        rows = sample['remote_pid_inventory']['observed_processes']
        require(type(rows) is list and len(rows) <= 4, 'Unexpected two-rank process count')
        require(all(type(row.get('rank')) is int and row['rank'] in (0, 1) for row in rows),
                'Observed process has no exact admitted rank')
        require(len({row['pid'] for row in rows}) == len(rows), 'One PID was attributed to multiple owners')
        for rank in range(2):
            directory = remote['rank_directories'][rank]
            for kind in ('native', 'supervisor'):
                require(sum(row['rank'] == rank and row['kind'] == kind for row in rows) <= 1,
                        'Repeated native or supervisor in one rank observation')
            for row in [value for value in rows if value['rank'] == rank]:
                require(type(row['command']) is str, 'Invalid observed command')
                words = row['command'].split()
                if row['kind'] == 'native':
                    require(directory + '/prompt.json' in words
                            and remote['rank_directories'][1 - rank] + '/prompt.json' not in words,
                            'Native command does not belong uniquely to its rank')
                    native_sets[rank].add(row['pid'])
                else:
                    require(row['kind'] == 'supervisor' and directory + '/rank.json' in words
                            and remote['rank_directories'][1 - rank] + '/rank.json' not in words,
                            'Supervisor command does not belong uniquely to its rank')
                    supervisor_sets[rank].add(row['pid'])
        native = sorted((row for row in rows if row['kind'] == 'native'), key=lambda row: row['rank'])
        if len(native) == 2:
            require([row['rank'] for row in native] == [0, 1], 'Simultaneous native sample lost a rank')
            simultaneous.append(dict(sampleIndex=index, nativePIDs=[row['pid'] for row in native],
                                     summedNativeRSSBytes=sum(row['rssBytes'] for row in native)))
    # A successful prospective 8K qualification requires an observed single
    # native and supervisor for each rank. Missing samples are never invented.
    owners = native_sets + supervisor_sets
    require(all(len(value) == 1 for value in owners), 'Each rank must have exactly one observed native and supervisor')
    require(len(set.union(*owners)) == 4, 'Rank/native/supervisor identities overlap or were restarted')
    summaries = receipt['observed_remote_processes']
    require(type(summaries) is list and len(summaries) == 2
            and [item['rank'] for item in summaries] == [0, 1], 'Observed rank summaries differ')
    per_rank = []
    for rank in range(2):
        summary = summaries[rank]
        require(summary['native_pids'] == sorted(native_sets[rank])
                and summary['supervisor_pids'] == sorted(supervisor_sets[rank]), 'Rank PID summary differs')
        view = copy.deepcopy(receipt)
        view['remote_paths']['native'] = remote['rank_directories'][rank]
        view['observed_remote_native_pids'] = summary['native_pids']
        view['observed_remote_supervisor_pids'] = summary['supervisor_pids']
        for sample in view['remote_memory_samples']:
            inventory = sample['remote_pid_inventory']
            inventory['observed_processes'] = [{key: value for key, value in row.items() if key != 'rank'}
                for row in inventory['observed_processes'] if row['rank'] == rank]
        checked = validate_resources(view)
        require(Decimal(checked['reportedSwapBaselineBytes']) == 0, 'Expected zero reported swap baseline')
        per_rank.append(dict(rank=rank, validation=checked))

    def control_reader(path):
        item = read(path)
        require(item['record']['kind'] == 'long_rank_control', 'Wrong saved rank-control namespace')
        adapted = copy.deepcopy(item)
        adapted['record']['kind'] = 'remote_prefill_control'
        return adapted

    sequence = controls_sequence(run / 'remote-observations', dict(receipt, run_id=receipt['epoch']), control_reader, sha)
    return dict(samples=len(samples), perRank=per_rank, simultaneousNativeSamples=simultaneous,
        simultaneousNativeSampleCount=len(simultaneous), maximumSimultaneouslyObservedNativeRSSBytes=max(
            (row['summedNativeRSSBytes'] for row in simultaneous), default=None),
        sourceBoundNativeProcessesObserved=2, sourceBoundSupervisorsObserved=2,
        supervisorsExcludedFromNativeSum=True, sampledRSSIsNotPeak=True,
        missingRSSNotAssumedZero=True, rawPsRSSIndependentlyReconstructed=False,
        crossProcessMonotonicOrderingAsserted=False), sequence
