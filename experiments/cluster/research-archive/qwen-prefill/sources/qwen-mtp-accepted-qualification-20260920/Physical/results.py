"""Join original launch/collection/resource observations; never infer lease release from EOF."""
import hashlib
import json
from pathlib import Path
import sys

from common import BASE, sha
sys.path.insert(0, str(BASE.parent / 'Compare'))
from audit_common import exact, fields, integer, parse
from recorded_math import require
from snapshot import snapshot


def pinned_json(path, wanted, cap=1024**2):
    item = snapshot(path, cap)
    exact(item['sha256'], wanted, 'Pinned prior result')
    return parse(item['raw'])


def reference_result(path, wanted, binding):
    result = pinned_json(path, wanted)
    for key, value in dict(schema='qwen9b_protected_ordinary_reference_result_v1', referenceCompleted=True,
        requestID=binding['requestID'], promptSHA256=binding['promptSHA256'], nativeSHA256=binding['referenceSHA256'],
        artifactSHA256=binding['offAgreement']['artifactAggregateSHA256'], stateEntries=72).items():
        exact(result[key], value, 'Actual prior reference ' + key)
    require(type(result['selectedTokenIDs']) is list and len(result['selectedTokenIDs']) == 8, 'Fresh reference O8 required')
    return result


def copies(paths, pins, expected_binding):
    result = []
    for rank in (0, 1):
        item = pinned_json(paths[rank], pins[rank])
        for key, value in dict(status='passed', rank=rank, bindingSHA256=expected_binding, modelOrOwnerLaunched=False).items():
            exact(item[key], value, 'Actual copy result ' + key)
        result.append(item)
    return result


def parent(path, wanted):
    result = pinned_json(path, wanted)
    for key, value in dict(runCompletedAndAliasRestored=True, controllerExitCode=0, leaseExitCode=0,
                           nativeProcessesAbsent=True, journalsEmpty=True, pinsUnchanged=True).items():
        exact(result[key], value, 'Actual parent ' + key)
    for key in ['reaped', 'groupAbsent']:
        exact(result['localController'][key], True, 'Actual controller ' + key)
    require('error' not in result and not result.get('cleanupUnconfirmed'), 'Parent recorded a failure')
    for row in result['outputFiles']:
        source = path.parent / row['path']
        exact(source.stat().st_size, row['bytes'], 'Parent output size')
        exact(sha(source), row['sha256'], 'Parent output pin')
    exact(result['leaseFinal'][0]['restored'], True, 'Original alias restoration')
    exact(len(result['leaseFinal']), 1, 'Single alias owner terminal')
    exact(result['monitors'], [dict(exitCode=0, errors=[])]*2, 'Both original monitor streams joined')
    return result


def controller(path, config, mode, binding, selected):
    raw = snapshot(path, 4*1024**2)['raw']; lines = raw.splitlines()
    require(len(lines) == 2 and raw.endswith(b'\n'), 'Complete started/terminal controller records')
    first, last = map(parse, lines)
    for key, value in dict(schema='owner_qualification_started_v1', configurationSHA256=sha(config), cpuQualification=False,
        membershipEpoch=binding[mode+'Agreement']['membershipEpoch'], requestID=binding['requestID'], promptCount=32,
        outputCount=8, performanceQualification=False, numericalQualification=False).items():
        exact(first[key], value, 'Actual controller start ' + key)
    for key, value in dict(schema='owner_qualification_result_v1', configurationSHA256=sha(config), cpuQualification=False,
        completed=True, tokenIDs=selected, finishReason='length', performanceQualification=False, numericalQualification=False,
        nativeCleanupObserved=[True,True], ownerDeviceLeaseReleasedObserved=[True,True]).items():
        exact(last[key], value, 'Actual controller terminal ' + key)
    integer(last['elapsedControllerNanoseconds'], 1, 305_000_000_000)
    return last


def resources(directory, reference_package):
    # Imports only the pinned sampler's parser; does not call sample_local.
    sys.path.insert(0, str(reference_package))
    from reference_resources import validate_local
    counts = []; minima = []
    for rank in (0,1):
        rows = snapshot(directory / ('resources-' + str(rank) + '.jsonl'), 8*1024**2)['raw'].splitlines()
        require(1 <= len(rows) <= 1400, 'Bounded retained parent observations')
        parsed = [parse(row) for row in rows]
        for ordinal, value in enumerate(parsed):
            exact(value['ordinal'], ordinal, 'Resource chronology')
            exact(value['admissible'], True, 'Every observed sample admitted')
            validate_local(value)
            exact(value['pressureLevel'], 1, 'Physical qualification requires observed normal pressure')
        counts.append(len(rows)); minima.append(min(x['actualFreeBytes'] for x in parsed))
    return dict(counts=counts, minimumActualFreeBytes=minima, normalPressure=True, zeroSwap=True, acPower=True)
