"""Closed v4 outer launch identities; inner numerical/action audit is separate."""
from .long_profile import ARTIFACT, CONFIGURATION, is_sha256
from . import long_stage_cut
from .common import require
from .long_identity import FLOW, canonical, sha, known_agreement, validate_request, environment_receipt

READY, FINAL = 'qwen_long_prefill_rank_ready', 'qwen_long_prefill_rank_report'
COMMON = {'kind','schemaVersion','epoch','rank','worldSize','transport','backend','flow','envelopeVersion',
          'agreementFingerprint','agreement','promptFileSHA256'}
HASH_FIELDS = {'storageCommitmentSHA256','planFingerprint','producerStageFingerprint','consumerStageFingerprint',
               'producerConstructionConfigurationSHA256','consumerConstructionConfigurationSHA256'}


def flags(record, **expected):
    for key, value in expected.items():
        require(type(record.get(key)) is bool and record[key] is value, 'Wrong native flag: ' + key)


def agreement(record, epoch, scheduling, inputs):
    value = record.get('agreement')
    known = known_agreement(epoch, scheduling, inputs)
    selected = long_stage_cut.agreement_fields(inputs)
    if selected:
        require(scheduling == inputs['stage_prefill_policy'], 'Selected scheduling context differs')
        known.update(selected)
    require(type(value) is dict and set(value) == set(known) | HASH_FIELDS, 'Unexpected v4 agreement fields')
    for key, expected in known.items():
        require(type(value[key]) is type(expected) and value[key] == expected, 'Agreement differs: ' + key)
    require(all(is_sha256(value[key]) for key in HASH_FIELDS), 'Invalid source/stage agreement hash')
    fingerprint = sha(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(value))
    require(record.get('agreementFingerprint') == fingerprint, 'V4 agreement fingerprint differs')


def validate(record, index, rank, epoch, scheduling, inputs, first=None):
    require(type(record) is dict, 'Rank record must be an object')
    fields = COMMON | ({'modelsReadyAgreementValidated','freshRequestStateCreated'} if index == 0 else
        {'completed','correctnessOnly','throughputMeasurementValid','modelForwardCompared','physicalTransferQualified',
         'sourceLoad','request','arithmeticEnvironment','arithmeticEnvironmentSHA256','resourceAdmission','execution',
         'allRequestStateRetired','modelReleased','memory'})
    require(set(record) == fields, 'Unexpected v4 rank record fields')
    for key, expected in dict(kind=READY if index == 0 else FINAL,schemaVersion=1,epoch=epoch,rank=rank,
        worldSize=2,transport='loopback-test',backend='ring',flow=FLOW,envelopeVersion=4,
        promptFileSHA256=inputs['prompt_file_sha256']).items():
        require(type(record[key]) is type(expected) and record[key] == expected, 'Rank identity differs: ' + key)
    agreement(record, epoch, scheduling, inputs)
    if index == 0:
        flags(record, modelsReadyAgreementValidated=True, freshRequestStateCreated=False)
        return
    flags(record,completed=True,correctnessOnly=True,throughputMeasurementValid=False,modelForwardCompared=False,
        physicalTransferQualified=False,allRequestStateRetired=True,modelReleased=True)
    require(first is not None and canonical(record['agreement']) == canonical(first['agreement'])
            and record['agreementFingerprint'] == first['agreementFingerprint'], 'Final agreement changed')
    validate_request(record['request'], epoch, inputs)
    source = record['sourceLoad']
    require(type(source) is dict and type(source.get('stageIndex')) is int and source['stageIndex'] == rank
        and source.get('verifiedAggregateSHA256') == ARTIFACT and source.get('sourceConfigurationSHA256') == CONFIGURATION,
        'Wrong verified local source/stage receipt')
    require(source.get('storageCommitmentSHA256') == record['agreement']['storageCommitmentSHA256'], 'Source storage agreement differs')
    bound_source = dict(schemaVersion=1, bf16ConversionEnabled=True, embeddingActivationDType='bfloat16',
        planSHA256=record['agreement']['planFingerprint'],
        stagePlanSHA256=record['agreement']['producerStageFingerprint' if rank == 0 else 'consumerStageFingerprint'],
        constructionConfigurationSHA256=record['agreement']['producerConstructionConfigurationSHA256' if rank == 0
                                                               else 'consumerConstructionConfigurationSHA256'])
    bound_source.update(long_stage_cut.source_fields(inputs))
    for key, expected in bound_source.items():
        require(type(source.get(key)) is type(expected) and source[key] == expected, 'Loaded stage identity differs: ' + key)
    require(canonical(record['arithmeticEnvironment']) == canonical(environment_receipt())
        and record['arithmeticEnvironmentSHA256'] == record['agreement']['arithmeticEnvironmentSHA256'], 'Arithmetic receipt differs')
    for name in ('resourceAdmission','execution'):
        require(type(record[name]) is dict and record[name], 'Missing opaque native ' + name)
    phases = ['before_stage_load','stage_loaded_no_request_state','stage_request_retired_weights_resident',
              'stage_model_released_cache_cleared']
    require(type(record['memory']) is list and len(record['memory']) == len(phases), 'Native memory phase count differs')
    for row, phase in zip(record['memory'], phases):
        require(type(row) is dict and set(row) == {'phase','activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart'}
            and row['phase'] == phase, 'Native memory phase differs')
        require(all(type(row[key]) is int and row[key] >= 0 for key in
            ('activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart')), 'Invalid native memory counters')
    require(record['memory'][-1]['cachedMLXBytes'] == 0, 'Native final cache-clear assertion differs')
    # Component inventories, residuals, actions, clocks, final logits and true
    # baseline comparison remain owned by the separately frozen CPU oracle.


def peers(readers):
    if all(reader.rows for reader in readers):
        require(canonical(readers[0].rows[0]['agreement']) == canonical(readers[1].rows[0]['agreement'])
            and readers[0].rows[0]['agreementFingerprint'] == readers[1].rows[0]['agreementFingerprint'],
            'Peers disagree on their complete v4 agreement')
