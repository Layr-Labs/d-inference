"""Exact journal/process/clock checks extracted from qualified resident replay."""
from Comparison.recorded_math import require
def integer(value,label):
    require(type(value) is int and value>=0,label+" integer")
    return value
EMPTY_SHA = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
JOURNAL_ID = ('path','directoryDevice','directoryInode','fileDevice','fileInode')
RESOURCE_KEYS = {'phase','startedMonotonicNS','completedMonotonicNS','timestampUTC','actualFreeBytes','pressureLevel','reportedSwapBytes','acPower','rawVMStat','rawMemory','rawPower'}
def interval(start,end,label,maximum=None):
    require(type(start) is int and type(end) is int and 0 <= start <= end,label+' clock')
    require(maximum is None or end-start<=maximum,label+' bound')

def journal(value, initial=None):
    require(set(value) == set(JOURNAL_ID) | {'bytes', 'sha256', 'exclusiveObservationLockAcquired',
                                         'journalMutationPerformed'}, 'Journal schema differs')
    require(value['path'] == '/Users/developer/.darkbloom/cluster-device/native-device.lease'
            and value['bytes'] == 0 and value['sha256'] == EMPTY_SHA
            and value['exclusiveObservationLockAcquired'] is True
            and value['journalMutationPerformed'] is False, 'Canonical journal is not observed empty')
    for name in JOURNAL_ID[1:]:
        require(integer(value[name], name) > 0, 'Journal identity is missing')
    if initial is not None:
        require(all(value[key] == initial[key] for key in JOURNAL_ID), 'Canonical journal inode changed')


def processes(value):
    require(set(value) == {'command', 'observedStartMonotonicNS', 'observedEndMonotonicNS',
                          'observerPID', 'processCount', 'prohibited', 'stdoutSHA256'},
            'Process observation schema differs')
    require(value['command'] == ['/bin/ps', '-Aww', '-o', 'pid=,uid=,comm=']
            and value['prohibited'] == [] and integer(value['processCount'], 'processCount') > 0
            and integer(value['observerPID'], 'observerPID') > 0,
            'Native/owner absence was not observed')
    require(type(value['stdoutSHA256']) is str and len(value['stdoutSHA256']) == 64
            and all(c in '0123456789abcdef' for c in value['stdoutSHA256']), 'Process output digest differs')
    interval(value['observedStartMonotonicNS'], value['observedEndMonotonicNS'],
             'Read-only process observation', 4_000_000_000)


def resource_clock(rows):
    require(2 <= len(rows) <= 2000, 'Resource sampling count is outside the supervisor bound')
    require(rows[0]['phase'] == 'prelaunch' and rows[-1]['phase'] == 'postflight'
            and sum(x['phase'] == 'prelaunch' for x in rows) == 1
            and sum(x['phase'] == 'postflight' for x in rows) == 1,
            'Missing or repeated initial/final resource checks')
    previous = 0
    for row in rows:
        require(set(row) == RESOURCE_KEYS, 'Raw resource schema differs')
        start, end = row['startedMonotonicNS'], row['completedMonotonicNS']
        interval(start, end, 'Resource observation', 10_000_000_000)
        require(previous <= start, 'Resource observation sequence overlaps or runs backwards')
        previous = end
    return rows[-1]['completedMonotonicNS'] - rows[0]['startedMonotonicNS']

