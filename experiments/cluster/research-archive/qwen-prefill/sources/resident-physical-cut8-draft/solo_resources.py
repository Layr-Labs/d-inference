"""Live local Mac screens and strict replay of the native resource DTO."""
from datetime import datetime, timezone
from decimal import Decimal
import re
import subprocess
import time
from stage_checks.common import integer, require
from solo_reference import fields

GIB = 1024**3


def native_resources(value, after=0):
    fields(value, 'os powerSource lowPowerModeEnabled thermalState sampledOutsideRequestClock '
           'wholeProcessMemorySafetyEstablished', 'native resource')
    require(value['powerSource'] == 'ac' and value['lowPowerModeEnabled'] is False
            and value['sampledOutsideRequestClock'] is True and value['wholeProcessMemorySafetyEstablished'] is False,
            'Native AC/power/resource scope differs')
    integer(value['thermalState'], 0, 1)
    os = value['os']
    fields(os, 'startedNanoseconds completedNanoseconds timestampUTC physicalMemoryBytes pageSizeBytes '
           'kernelFreePages freePages inactivePages speculativePages actualFreeBytes estimatedReclaimableBytes '
           'pressureLevel swapUsedBytes', 'native OS resource')
    for key in os:
        if key != 'timestampUTC': integer(os[key], 0, 2**64-1 if key.endswith('Nanoseconds') else 2**63-1)
    require(type(os['timestampUTC']) is str and 1 <= len(os['timestampUTC']) <= 64, 'Native timestamp missing')
    datetime.fromisoformat(os['timestampUTC'].replace('Z','+00:00'))
    start, stop = os['startedNanoseconds'], os['completedNanoseconds']
    require(start >= after and start <= stop <= start+10**9, 'Native resource order/duration differs')
    page = integer(os['pageSizeBytes'],1)
    require(os['kernelFreePages'] == os['freePages']+os['speculativePages']
            and os['actualFreeBytes'] == os['freePages']*page
            and os['estimatedReclaimableBytes'] == (os['freePages']+os['inactivePages']+os['speculativePages'])*page
            and 6*GIB <= os['actualFreeBytes'] <= os['estimatedReclaimableBytes'] <= os['physicalMemoryBytes']
            and os['pressureLevel'] <= 2 and os['swapUsedBytes'] == 0, 'Native resource gate/accounting differs')
    return stop


def read_command(command):
    result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                            text=True, timeout=3, check=True)
    require(not result.stderr and len(result.stdout.encode()) <= 65536, 'Resource observation output differs')
    return result.stdout


def sample_local(read=read_command):
    start = time.monotonic_ns()
    memory = read(['/usr/sbin/sysctl','-n','kern.memorystatus_vm_pressure_level','vm.swapusage'])
    vm = read(['/usr/bin/vm_stat'])
    power = read(['/usr/bin/pmset','-g','batt'])
    page = re.search(r'page size of (\d+) bytes',vm)
    # Apple's vm_stat prints free_count - speculative_count as "Pages free".
    # Do not subtract speculative pages a second time. Retained primary source:
    # system_cmds 408bba7453608006b89772db185defbac8fe2fd0, vm_stat.c:132.
    free = re.search(r'Pages free:\s+(\d+)\.',vm)
    swap = re.search(r'used\s*=\s*([0-9.]+)([MG])',memory)
    require(page and free and swap and re.fullmatch(r'\d+',memory.splitlines()[0]), 'Unparseable Mac resource data')
    swap_bytes = Decimal(swap[1])*(1024**2 if swap[2]=='M' else 1024**3)
    return dict(startedMonotonicNS=start, completedMonotonicNS=time.monotonic_ns(),
        timestampUTC=datetime.now(timezone.utc).isoformat(), actualFreeBytes=int(page[1])*int(free[1]),
        pressureLevel=int(memory.splitlines()[0]), reportedSwapBytes=str(swap_bytes),
        acPower="Now drawing from 'AC Power'" in power,
        rawVMStat=vm, rawMemory=memory, rawPower=power)


def validate_local(value):
    require(value['actualFreeBytes'] >= 6*GIB and type(value['actualFreeBytes']) is int,
            'Parent requires 6 GiB actual free')
    integer(value['pressureLevel'],0,2)
    require(Decimal(value['reportedSwapBytes']) == 0 and value['acPower'] is True,
            'Parent requires zero swap and AC')
    require(0 <= value['startedMonotonicNS'] <= value['completedMonotonicNS']
            and value['completedMonotonicNS']-value['startedMonotonicNS'] <= 10*10**9,
            'Parent resource sampling exceeded its bound')


class ResourceGate:
    def __init__(self, publish, sample=sample_local, clock=time.monotonic):
        self.publish, self.sample, self.clock = publish, sample, clock
        self.last = None; self.samples = 0

    def __call__(self, phase):
        now = self.clock()
        force = phase in ('prelaunch','postflight') or phase.startswith('before-request-')
        if not force and self.last is not None and 0 <= now-self.last < 0.25:
            return
        require(self.samples < 2000, 'Resource sample count exceeded bound')
        value = self.sample(); self.samples += 1
        self.publish(dict(phase=phase, **value))  # Retain a refused observation too.
        validate_local(value)
        self.last = self.clock()
