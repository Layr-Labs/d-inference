"""Validate the installed CLI's existing diagnostics DTO, not saved-file liveness."""
import json
import uuid

EXPECTED_CLUSTER = 'darkbloom-product-qwen9b-diagnostics-20260915'
EXPECTED_PREFILL_SCHEDULE = 'one_chunk_lookahead_v1'
EXPECTED_PEERS = ('darkbloom-24', 'darkbloom-48')
MAXIMUM_STDOUT = 65536


def require(value, message):
    if not value:
        raise ValueError('Cluster status: ' + message)


def object_pairs(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'duplicate JSON field')
        value[key] = item
    return value


def integer(value, lower, upper):
    return type(value) is int and lower <= value <= upper


def reject_constant(_):
    raise ValueError('Cluster status: nonfinite JSON value')


def canonical_uuid(value):
    try:
        return type(value) is str and str(uuid.UUID(value)) == value
    except (ValueError, AttributeError):
        return False


def validate(raw, previous=None):
    require(0 < len(raw) <= MAXIMUM_STDOUT, 'stdout byte bound')
    try:
        value = json.loads(raw, object_pairs_hook=object_pairs, parse_constant=reject_constant)
        require(type(value) is dict, 'report object required')
        require(value['schema'] == 'darkbloom_cluster_diagnostics_v1' and value['operation'] == 'status'
                and value['configurationState'] == 'verified', 'verified status report required')
        require(value['physicalProbePerformed'] is False and value['recoveryPerformed'] is False,
                'status must remain observational')
        saved, live = value['saved'], value['live']
        require(type(saved) is dict and type(live) is dict, 'live response was not observed')
        session = live['session']
        require(saved == live['binding'] == session['binding'], 'saved/live/session binding differs')
        require(saved['clusterID'] == EXPECTED_CLUSTER and saved['role'] == 'leader'
                and saved['publicModelID'] == 'Qwen3.5-9B'
                and saved['runtimeModelID'] == 'registered_qwen35_9b', 'selected cluster/model differs')
        require(saved['maximumRequests'] == 16 and saved['maximumLifetimeSeconds'] == 300,
                'installed lifetime/quota differs')
        require(live['schema'] == 'darkbloom_cluster_status_v1'
                and live['authenticationConfigured'] is True and live['boundPort'] == 18081,
                'live endpoint/authentication differs')
        require(live['hostPhase'] == 'serving' and live['ready'] is True and live['failed'] is False
                and live['quarantined'] is False and session['phase'] == 'ready' and session['ready'] is True,
                'leader/session is not live ready')
        epoch, nonce = session['observedMembershipEpoch'], live['nonce']
        require(canonical_uuid(epoch) and canonical_uuid(nonce), 'actual epoch/nonce not observed')
        require(session['observedPrefillSchedule'] == saved['prefillSchedule'] == EXPECTED_PREFILL_SCHEDULE,
                'selected lookahead raw schedule differs')
        require(session['mtpEnabled'] is False and session['mtpOffReason'] == 'runtimeCapabilityDisablesSpeculation',
                'unexpected speculation state')
        peers, members = saved['peers'], session['members']
        require(type(peers) is list and type(members) is list and len(peers) == len(members) == 2,
                'exactly two members required')
        require(tuple(peer['id'] for peer in peers) == EXPECTED_PEERS
                and saved['memberID'] == EXPECTED_PEERS[0], 'leader/member identity differs')
        for rank, member in enumerate(members):
            require(type(member['rank']) is int and type(peers[rank]['rank']) is int
                    and member['rank'] == rank == peers[rank]['rank']
                    and member['peerID'] == peers[rank]['id'], 'rank/member binding differs')
            require(member['transport'] == ('localPipes' if rank == 0 else 'authenticatedSSH')
                    and member['nativeReady'] is True and integer(member['requestCapacityBytes'], 1, 2**63 - 1),
                    'actual two-rank native readiness not observed')
            require(member['nativeCleanupObserved'] is False and member['ownerReleaseAcknowledged'] is False
                    and member.get('ownerTermination') is None, 'member already terminating')
        admission = session['admission']
        require(admission['valid'] is True and admission['draining'] is False
                and integer(admission['remainingLifetimeNanoseconds'], 1, 300_000_000_000)
                and integer(admission['remainingRequests'], 0, 16)
                and type(admission['activeRequest']) is bool, 'live admission observation invalid')
        checks = value['checks']
        require(type(checks) is list and len(checks) <= 16, 'check inventory differs')
        outcomes = {item['name']: item['outcome'] for item in checks}
        require(len(outcomes) == len(checks) and 'failed' not in outcomes.values()
                and outcomes.get('savedConfiguration') == 'passed'
                and outcomes.get('localServingObservation') == 'passed', 'saved or live status check failed')
        if previous is None:
            require(live['admissionAvailable'] is True and admission['activeRequest'] is False
                    and admission['remainingRequests'] == 16, 'fresh idle session required before smoke')
        else:
            require(saved == previous['binding'] and epoch == previous['observedMembershipEpoch']
                    and nonce != previous['nonce'], 'post-request epoch/binding is changed or stale')
            require(admission['remainingRequests'] == previous['remainingRequests'] - 1,
                    'one-request admission counter differs')
        return {'validated': True, 'binding': saved, 'observedMembershipEpoch': epoch,
                'nonce': nonce, 'nativeReadyRanks': [0, 1],
                'remainingRequests': admission['remainingRequests'],
                'remainingLifetimeNanoseconds': admission['remainingLifetimeNanoseconds'],
                'activeRequest': admission['activeRequest'], 'admissionAvailable': live['admissionAvailable'],
                'scope': 'Fresh CLI live observation; not a native cleanup or capacity lease proof'}
    except (KeyError, TypeError, IndexError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError('Cluster status: missing or malformed required DTO fields') from error
