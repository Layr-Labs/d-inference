"""Fail-closed OS observations, separate from tensor/RSS accounting."""

from decimal import Decimal
import re
import subprocess
import time


def sample_memory():
    result = subprocess.run(['/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level',
                             'vm.swapusage'], check=True, capture_output=True, text=True, timeout=1)
    lines = result.stdout.strip().splitlines()
    if len(lines) != 2 or len(result.stdout) > 4096:
        raise ValueError('Unexpected bounded sysctl memory output')
    pressure = int(lines[0])
    match = re.search(r'\bused\s*=\s*([0-9]+(?:\.[0-9]+)?)([KMGT])\b', lines[1])
    if match is None:
        raise ValueError('Unable to parse swap usage')
    used = Decimal(match[1]) * (1024 ** ('KMGT'.index(match[2]) + 1))
    # Preserve the printed precision: this is an OS-reported byte estimate, not
    # an assertion that sysctl exposes every page at single-byte resolution.
    return dict(monotonic_seconds=time.monotonic(), pressure_level=pressure,
                swap_used_bytes=str(used), raw_sysctl=result.stdout)


class MemoryGate:
    def __init__(self, sample=sample_memory):
        self.sample, self.samples = sample, []
        first = self.observe()
        self.initial_swap = Decimal(first['swap_used_bytes'])

    def observe(self):
        value = self.sample()
        self.samples.append(value)
        if type(value['pressure_level']) is not int or not 0 <= value['pressure_level'] <= 2:
            raise ValueError('Memory pressure exceeds level 2')
        swap = Decimal(value['swap_used_bytes'])
        if not swap.is_finite() or swap < 0:
            raise ValueError('Invalid swap observation')
        if hasattr(self, 'initial_swap') and swap > self.initial_swap:
            raise ValueError('New OS-reported swap usage during stage transport check')
        return value


def resource_preflight(output):
    import resource
    import shutil
    from pathlib import Path
    raw=subprocess.run(['/usr/bin/vm_stat'],check=True,capture_output=True,text=True,timeout=2).stdout
    page=re.search(r'page size of (\d+) bytes',raw)
    if page is None or len(raw)>16384: raise ValueError('Invalid bounded vm_stat output')
    pages={}
    for line in raw.splitlines()[1:]:
        match=re.fullmatch(r'(.+?):\s+(\d+)\.',line)
        if match: pages[match[1]]=int(match[2])
    available=sum(pages[key] for key in ('Pages free','Pages inactive','Pages speculative'))*int(page[1])
    soft,hard=resource.getrlimit(resource.RLIMIT_NOFILE)
    opened=len(list(Path('/dev/fd').iterdir()))
    disk=shutil.disk_usage(output).free
    record=dict(estimated_reclaimable_bytes=available,required_reclaimable_bytes=8*1024**3,
        formula='(free + inactive + speculative) * page_size; overlapping categories excluded',
        estimate_is_not_memory_guarantee=True,vm_stat=raw,nofile_soft=soft,nofile_hard=hard,
        open_descriptors=opened,disk_free_bytes=disk,required_disk_free_bytes=4*1024**3)
    record['passed']=available>=8*1024**3 and soft>=256 and opened+128<soft and disk>=4*1024**3
    return record
