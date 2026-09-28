"""Join registered Qwen run identities to fresh local phase replay.

Numerical/runtime audit references and hardware identity are caller assertions;
this converter neither replays those audits nor grants model eligibility.
"""

import re
from types import SimpleNamespace

from runtime.stage_checks.common import digest, parse
from runtime.stage_checks import long_rank_contract, long_stage_cut
from runtime.stage_checks.long_inputs import prompt_ids
from runtime.stage_checks.long_profile import ARTIFACT, CONFIGURATION
from ..costs import fields, label, require, sha
from .inputs import PacketInputs, stdout_rows
from .ownership import reported_ownership


PROVENANCE_HASHES = ('native_sha256', 'runtime_source_sha256',
                     'numerical_audit_sha256', 'runtime_audit_sha256')


def provenance(value):
    fields(value, ' '.join(PROVENANCE_HASHES) + ' devices', 'provenance')
    for name in PROVENANCE_HASHES:
        sha(value[name], name)
    devices = value['devices']
    require(type(devices) is list and len(devices) == 2, 'Two observed rank placements required')
    for device in devices:
        fields(device, 'id hardware_sha256', 'observed device')
        label(device['id'], 'observed device id')
        sha(device['hardware_sha256'], 'observed hardware profile')
    # This adapter consumes only the currently admitted local loopback format.
    require(devices[0] == devices[1], 'Loopback observations require the same declared device')
    return value


def outer_reports(inputs):
    prompt = prompt_ids(inputs.raw['prompt'])
    rows = [stdout_rows(inputs.raw[f'rank{rank}_stdout']) for rank in range(2)]
    first = rows[0][0]
    require(type(first) is dict and type(first.get('agreement')) is dict, 'Missing initial agreement')
    epoch, policy = first.get('epoch'), first['agreement'].get('schedulingPolicy')
    require(type(epoch) is str and re.fullmatch('[0-9a-f]{32}', epoch), 'Invalid cohort epoch')
    require(policy in ('serial_v1', 'prompt_lookahead_one_v1'), 'Unsupported observed policy')
    cut = long_stage_cut.option('long-prefill-ranks', inputs.packet['stage_cut'], policy)
    context = dict(mode='long-prefill-ranks', epoch=epoch, prompt=prompt, artifact=ARTIFACT,
                   configuration_sha256=CONFIGURATION, prompt_file_sha256=digest(inputs.raw['prompt']),
                   prompt_token_ids_sha256=digest(','.join(map(str, prompt)).encode()),
                   stage_prefill_policy=policy, stage_logits_dtype='bfloat16')
    if cut is not None:
        context['stage_cut'] = cut
    for rank, values in enumerate(rows):
        for index, row in enumerate(values):
            long_rank_contract.validate(row, index, rank, epoch, policy, context,
                                        first=values[0] if index else None)
    long_rank_contract.peers([SimpleNamespace(rows=values) for values in rows])
    return [values[1] for values in rows], context


def extract(path):
    # Imported here so the file/input layer has no dependency on phase fixtures.
    from .qwen_rank_phase import validate_phase_pair

    inputs = PacketInputs(path)
    declared = provenance(inputs.packet['provenance'])
    try:
        reports, context = outer_reports(inputs)
        traces = [parse(inputs.raw[f'rank{rank}_trace']) for rank in range(2)]
        phase = validate_phase_pair(reports, traces)
    except (KeyError, TypeError, AttributeError, IndexError) as error:
        raise ValueError('Malformed native or phase record: ' + str(error)) from error
    agreement = reports[0]['agreement']
    layouts = [record['sourceLoad'].get('sourceParameterLayoutSHA256') for record in reports]
    for layout in layouts:
        if layout is not None:
            sha(layout, 'source parameter layout')
    result = dict(
        schema='cluster_prefill_services_v1', adapter='registered_qwen_9b_long_rank_v1',
        packet_sha256=inputs.sha256, input_files=inputs.metadata,
        workload=dict(artifact_sha256=agreement['artifactAggregateSHA256'],
                      tokens_sha256=context['prompt_file_sha256'],
                      arithmetic=agreement['arithmeticEnvironmentSHA256'],
                      prompt_tokens=8192, chunk_tokens=512, batch_size=1, cache_mode='uncached'),
        source=dict(configuration_sha256=agreement['sourceConfigurationSHA256'],
                    plan_sha256=agreement['planFingerprint'],
                    storage_commitment_sha256=agreement['storageCommitmentSHA256'],
                    stage_sha256=[agreement['producerStageFingerprint'], agreement['consumerStageFingerprint']],
                    stage_configuration_sha256=[agreement['producerConstructionConfigurationSHA256'],
                                                agreement['consumerConstructionConfigurationSHA256']],
                    source_parameter_layout_sha256=layouts,
                    reported_stage_ownership=reported_ownership(reports)),
        observed=dict(policy=agreement['schedulingPolicy'], resource_layout='shared_device',
                      stage_cut=context.get('stage_cut'), epoch=agreement['epoch'],
                      agreement_sha256=reports[0]['agreementFingerprint'],
                      recorded_request_sha256=agreement['recordedRequestFingerprint'],
                      provenance=declared),
        phase=phase,
        local_phase_replayed=True, raw_input_hashes_verified=True,
        numerical_audit_replayed=False, runtime_provenance_audit_replayed=False,
        hardware_identity_verified=False, native_execution_performed=False,
        physical_performance_qualified=False, execution_admission=False,
    )
    inputs.recheck()
    return result
