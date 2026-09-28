"""Explicit transfer-of-service assumption; all unmeasured costs stay unknown."""

from runtime.stage_checks.common import canonical, digest
from ..costs import label, read_profile, require


def assumed_profile(services, devices, policy=None):
    require(services['schema'] == 'cluster_prefill_services_v1', 'Unsupported service schema')
    require(type(devices) in (list, tuple) and len(devices) == 2, 'Two assumed devices required')
    for device in devices:
        label(device, 'assumed device')
    require(devices[0] != devices[1], 'Independent device identities must differ')
    policy = policy or services['observed']['policy']
    require(policy in ('serial_v1', 'prompt_lookahead_one_v1'), 'Unsupported cost policy')
    ranks = services['phase']['ranks']
    prepare, consume = ranks[0]['services'], ranks[1]['services']
    require(len(prepare) == len(consume) == 16, 'Recorded services must cover every chunk')
    frames = []
    for index, (producer, consumer) in enumerate(zip(prepare, consume)):
        for key in ('frameSequence', 'tokenOffset', 'tokenCount', 'committedTokens'):
            require(producer[key] == consumer[key], 'Service frontiers differ across ranks')
        require(producer['frameSequence'] == index, 'Service frame order differs')
        require(producer['includesFinalSelection'] is False
                and consumer['includesFinalSelection'] is (index == 15), 'Final selection scope differs')
        point = lambda value: dict(low=value, typical=value, high=value)
        frames.append(dict(prepare_ns=point(producer['elapsedNanoseconds']),
                           consume_ns=point(consumer['elapsedNanoseconds']),
                           handoff_ns=None, completion_ns=None))
    identity = services['observed']['provenance']
    references = [services['packet_sha256'], digest(canonical(services)),
                  identity['native_sha256'], identity['runtime_source_sha256'],
                  identity['numerical_audit_sha256'], identity['runtime_audit_sha256']]
    result = dict(schema='cluster_prefill_costs_v1', workload=services['workload'], baseline=None,
                  candidates=[dict(id='assumed-' + policy, plan_sha256=services['source']['plan_sha256'],
                                   devices=list(devices), resource_layout='independent_devices', policy=policy,
                                   evidence_kind='assumed', source_sha256=list(dict.fromkeys(references)),
                                   memory=[dict(peak_bytes=None, budget_bytes=None) for _ in range(2)],
                                   startup_ns=None, return_token_ns=None, frames=frames)])
    read_profile(result)
    return result
