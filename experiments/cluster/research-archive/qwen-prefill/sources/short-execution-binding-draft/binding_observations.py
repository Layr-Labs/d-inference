"""Replay recorded parent policy statements; never label them fresh OS evidence."""
from datetime import datetime
import math
from binding_common import fields, integer, require, same

BASE = set('timestampUTC monotonicSeconds pressureLevel reportedSwapBytes actualFreeBytes rawMemory rawVMStat nativeRSSBytes missingRSSIsNotZero'.split())
OWNED = set('nativePID nativePGID nativeCommand'.split())
TERMINAL = set('terminalExitCodeObservedAfterSample nativeObservationClassification defunctSampleIsLiveRSS'.split())


def timestamp(value):
    require(type(value) is str and len(value) <= 64, 'Invalid recorded timestamp')
    parsed = datetime.fromisoformat(value)
    require(parsed.tzinfo is not None and parsed.utcoffset().total_seconds() == 0,
            'Recorded timestamp must have UTC offset')
    return parsed


def raw_text(value, maximum):
    require(type(value) is str and 0 < len(value.encode()) <= maximum and '\x00' not in value,
            'Invalid raw observation text')


def replay_observations(parent, contract, executable):
    memory, power = parent['memorySamples'], parent['powerObservations']
    require(type(memory) is list and type(power) is list and 3 <= len(memory) <= 1024
            and len(memory) == len(power), 'Parent observation coverage differs')
    timestamp(parent['startedAtUTC']); timestamp(parent['finishedAtUTC'])
    previous, live_count, terminal_count = None, 0, 0
    profile = contract.PROFILES[parent['registeredProfile']]
    for index, (sample, battery) in enumerate(zip(memory, power)):
        require(type(sample) is dict, 'Invalid memory sample')
        keys = set(sample)
        require(BASE <= keys <= BASE | OWNED | TERMINAL, 'Parent sample keys differ')
        timestamp(sample['timestampUTC'])
        monotonic = sample['monotonicSeconds']
        require(type(monotonic) in (int, float) and math.isfinite(monotonic) and monotonic >= 0
                and (previous is None or monotonic >= previous), 'Recorded monotonic sample order differs')
        previous = monotonic
        same(sample['missingRSSIsNotZero'], True, 'missing RSS interpretation')
        integer(sample['pressureLevel'], 'recorded pressure', high=2)
        integer(sample['actualFreeBytes'], 'recorded free bytes')
        raw_text(sample['reportedSwapBytes'], 128)
        for name in ('rawMemory', 'rawVMStat'):
            raw_text(sample[name], 2*1024**2)
        rss = sample['nativeRSSBytes']
        if rss is None:
            require(not keys.intersection(OWNED | TERMINAL), 'Missing RSS has fabricated process fields')
        else:
            require(OWNED <= keys and index not in (0, 1, len(memory)-1), 'Owned sample is outside live observation slots')
            integer(rss, 'recorded RSS')
            same(sample['nativePID'], parent['nativePID'], 'observed PID')
            same(sample['nativePGID'], parent['nativePID'], 'observed process group')
            raw_text(sample['nativeCommand'], 65536)
            live_count += 1
        terminal = None
        if sample.get('nativeCommand') == '<defunct>':
            require(TERMINAL <= keys and index == len(memory)-2 and terminal_count == 0,
                    'Terminal sample lacks its final owned observation slot')
            same(sample['terminalExitCodeObservedAfterSample'], 0, 'terminal code')
            same(sample['nativeObservationClassification'], 'owned_terminal_during_observation', 'terminal classification')
            same(sample['defunctSampleIsLiveRSS'], False, 'terminal RSS interpretation')
            terminal = 0
            terminal_count += 1
        else:
            require(not keys.intersection(TERMINAL), 'Live sample has terminal metadata')
        contract.resource_policy(sample, profile, parent['nativePID'] if rss is not None else None,
                                 executable, terminal_exit_code=terminal)
        fields(battery, 'timestampUTC raw admission', 'power observation')
        timestamp(battery['timestampUTC'])
        same(battery['admission'], contract.power_policy(battery['raw']), 'recorded power policy')
    return dict(sampleCount=len(memory), ownedSamples=live_count, terminalSamples=terminal_count,
                savedPolicyStatementsReplayed=True, rawOSObservationIndependentlyVerified=False,
                liveRSSObservedByAuditor=False, measuredWholeProcessPeakBytes=None,
                monotonicExecutionDeadlineIndependentlyVerified=False)
