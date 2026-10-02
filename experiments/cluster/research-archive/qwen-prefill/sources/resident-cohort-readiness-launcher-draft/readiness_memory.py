"""Saved tiny-policy observations and exact owned local process attribution."""
from datetime import datetime, timezone
from decimal import Decimal
import re
import subprocess
import time
from readiness_config import require


def read_command(arguments, timeout=3):
    result = subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=timeout)
    require(not result.stderr and len(result.stdout.encode()) <= 2 * 1024**2,
            'Unexpected bounded observation output')
    return result.stdout


def parse_resources(memory, vm):
    lines = memory.strip().splitlines()
    page = re.search(r'page size of (\d+) bytes', vm)
    free = re.search(r'Pages free:\s+(\d+)\.', vm)
    swap = re.search(r'\bused\s*=\s*([0-9]+(?:\.[0-9]+)?)([KMGT])\b', memory)
    require(len(lines) == 2 and lines[0].isdigit() and page and free and swap,
            'Cannot parse tiny resource observation')
    require(int(page[1]) > 0, 'Invalid VM page size')
    return dict(pressure_level=int(lines[0]),
        actual_free_bytes=int(page[1]) * int(free[1]),
        reported_swap_bytes=str(Decimal(swap[1]) * 1024 ** ('KMGT'.index(swap[2]) + 1)),
        raw_memory=memory, raw_vm_stat=vm)


def process_rows(raw):
    rows = []
    for line in raw.splitlines():
        fields = line.strip().split(None, 4)
        require(len(fields) == 5 and all(x.isdigit() for x in fields[:4]),
                'Invalid process inventory row')
        pid, ppid, pgid, rss = map(int, fields[:4])
        rows.append(dict(pid=pid, ppid=ppid, pgid=pgid, rss_bytes=rss * 1024, command=fields[4]))
    return rows


class Observations:
    def __init__(self, output, read=read_command, clock=time.monotonic):
        self.output, self.read, self.clock = str(output), read, clock
        self.samples, self.supervisors, self.observed_native = [], {}, {}
        self.initial_swap = None

    def started(self, rank, process):
        require(rank['host'] is None and rank['rank'] not in self.supervisors,
                'Unexpected or repeated local supervisor')
        self.supervisors[rank['rank']] = process.pid

    def observe(self, initial_free=False, refuse_existing=False, deadline=None):
        def read(arguments):
            remaining = 3 if deadline is None else min(3, deadline - self.clock())
            if remaining <= 0:
                raise TimeoutError('Parent deadline reached during observation')
            try:
                return self.read(arguments, timeout=remaining)
            except subprocess.TimeoutExpired:
                if deadline is not None and self.clock() >= deadline:
                    raise TimeoutError('Parent deadline reached during bounded observation')
                raise
        value = parse_resources(read(['/usr/sbin/sysctl', '-n',
            'kern.memorystatus_vm_pressure_level', 'vm.swapusage']), read(['/usr/bin/vm_stat']))
        rows = process_rows(read(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,rss=,command=']))
        owned = []
        for row in rows:
            for rank, pid in self.supervisors.items():
                supervisor_command = self.output + '/rank-' + str(rank) + '/rank.json'
                if row['pid'] == pid:
                    require(supervisor_command in row['command'] and row['pgid'] == pid,
                            'Owned supervisor command/group changed')
                    owned.append(dict(row, rank=rank, role='supervisor'))
                if row['ppid'] == pid and self.output + '/bundle/cluster-inference ' in row['command']:
                    require(row['pgid'] == row['pid'], 'Native child did not retain its owned process group')
                    self.observed_native[row['pid']] = dict(row, rank=rank)
                    owned.append(dict(row, rank=rank, role='native'))
        value.update(timestamp_utc=datetime.now(timezone.utc).isoformat(),
            monotonic_seconds=self.clock(), owned_processes=owned, missing_rss_is_not_zero=True)
        self.samples.append(value)
        swap = Decimal(value['reported_swap_bytes'])
        require(0 <= value['pressure_level'] <= 2 and swap.is_finite() and swap >= 0,
                'Tiny memory pressure/swap admission refused')
        if self.initial_swap is None:
            self.initial_swap = swap
        require(swap <= self.initial_swap, 'New OS-reported swap usage during readiness cohort')
        if initial_free:
            require(value['actual_free_bytes'] >= 1024**3, 'Tiny actual-free screen requires one GiB')
        if refuse_existing:
            require(not any('/cluster-inference ' in r['command'] or '/rank_worker.py ' in r['command']
                            for r in rows), 'Another native inference experiment is active')
        return value

    def postflight(self):
        raw = self.read(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,rss=,command='])
        rows = process_rows(raw)
        pids = set(self.supervisors.values()) | set(self.observed_native)
        remaining = [r for r in rows if r['pid'] in pids or r['pgid'] in pids or
                     self.output + '/bundle/cluster-inference ' in r['command'] or
                     any(self.output + '/rank-' + str(rank) + '/rank.json' in r['command']
                         for rank in (0, 1))]
        return dict(observed_remaining=remaining, raw_ps=raw,
                    sampled_native_processes=list(self.observed_native.values()),
                    independent_native_waitpid=False)
