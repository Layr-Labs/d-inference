"""Closed administrative exception for two exact failed-run journals, never a general recovery permit."""
import hashlib
import json
from pathlib import Path
from recovery_files import RecoveryRefusal, require, read_private_file

CANONICAL_DIRECTORY = '/Users/developer/.darkbloom/cluster-device'
CONTROLLER_SHA = 'a628f325c1c26f86827034407df4196190dbc1364f16e07ca03eb0088f39a17c'
EXECUTION_SHA = 'ab281641e32fda8fc930960ccea5ed6dd1b69be0f2252c917a052633f2ed63cf'
CLUSTER = 'qwen9b-single-mtp-proposal'
EPOCH = '6a5c1ca9-076f-4392-85fa-a7fbf33c3f68'
REQUEST = '18901e32-47f8-4fc8-a8bd-ec3fbdcf118e'
CONFIGURATION_SHA = 'aa408cbc74fbaff5f0fc5b8ef03e6e404dc7c0e02b2ad4509ee22b0a8632b011'
CASES = [
    dict(peerID='darkbloom-24', leaseID='c37094c0-f9d9-4ed0-a582-dbb9f3fc4e39',
         nativeLaunchID='01f502eb-3790-4c90-8c7a-87be5be4a52f',
         ownerIncarnation='e9c3a233-94c2-4d55-88db-8a8b85d57aff',
         sha256='a733ffea03efc48b822514376b05705f5309cc10159166340185a1d10684c108'),
    dict(peerID='darkbloom-48', leaseID='9c1c42d9-4bf6-4005-a028-1922a0834dfb',
         nativeLaunchID='8041ba87-3d2a-418c-a529-89e66e191719',
         ownerIncarnation='0cb0d2e4-67c8-4ef6-8b70-53ea34161832',
         sha256='1d94001e59188d44d8e420470037ed79075249f23d1219f280bf41ca5ca8a1a4')]


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def parse(raw):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    def bad_number(_):
        raise RecoveryRefusal('Nonfinite JSON number')
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=bad_number)


def known_journal(rank, raw):
    require(type(rank) is int and rank in (0, 1), 'Only the two known ranks are allowed')
    case = CASES[rank]
    require(len(raw) == 333 and digest(raw) == case['sha256'], 'Not the exact known journal bytes')
    expected = dict(schema='darkbloom_native_lease_v1', clusterID=CLUSTER, membershipEpoch=EPOCH,
                    rank=rank, **{k:v for k,v in case.items() if k != 'sha256'})
    actual = parse(raw)
    require(type(actual) is dict and type(actual.get('rank')) is int
            and actual == expected and set(actual) == set(expected), 'Journal schema or identity differs')
    return expected


def evidence(directory, rank, peer, journal_sha, controller_sha):
    require(type(rank) is int and rank in (0, 1), 'Unknown recovery rank')
    require(peer == CASES[rank]['peerID'] and journal_sha == CASES[rank]['sha256']
            and controller_sha == CONTROLLER_SHA, 'Explicit recovery identity pins differ')
    names = {'controller.stdout.jsonl': (CONTROLLER_SHA, 996),
             'execution.json': (EXECUTION_SHA, 14635),
             'rank%d-journal.json' % rank: (journal_sha, 333)}
    raw = {}
    for name, (expected, size) in names.items():
        data = read_private_file(Path(directory) / name, size)
        require(len(data) == size and digest(data) == expected, 'Pinned failed-run evidence differs: ' + name)
        raw[name] = data
    journal = known_journal(rank, raw['rank%d-journal.json' % rank])
    lines = raw['controller.stdout.jsonl'].split(b'\n')
    require(len(lines) == 3 and lines[-1] == b'', 'Complete controller records required')
    started, ended = [parse(line) for line in lines[:2]]
    require(started['schema'] == 'owner_qualification_started_v1' and started['membershipEpoch'] == EPOCH
            and started['requestID'] == REQUEST and started['configurationSHA256'] == CONFIGURATION_SHA
            and started['cpuQualification'] is False, 'Failed controller origin differs')
    require(ended['schema'] == 'owner_qualification_result_v1' and ended['completed'] is False
            and ended['configurationSHA256'] == CONFIGURATION_SHA
            and ended['nativeCleanupObserved'] == [True, True]
            and ended['ownerDeviceLeaseReleasedObserved'] == [False, False]
            and ended['failure'] == 'Missing authenticated device lease release acknowledgment',
            'Actual failed controller/native-cleanup evidence required')
    parent = parse(raw['execution.json'])
    require(parent['controllerExitCode'] == 1 and parent['localController']['reaped'] is True
            and parent['localController']['groupAbsent'] is True
            and parent['nativeProcessesAbsent'] is True and parent['journalsEmpty'] is False,
            'Parent completion and process observations differ')
    observed = parent['remoteCleanup']['postflight'][rank]
    require(observed['active'] == [] and observed['journalBytes'] == 333
            and observed['journalSHA256'] == journal_sha, 'Captured journal/process binding differs')
    return journal, raw
