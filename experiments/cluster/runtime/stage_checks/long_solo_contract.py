"""Closed solo outer identity; digest/selection/timing audit remains separate."""
import uuid
from .common import canonical, digest, exact, flags, require, sha
from .long_identity import environment_receipt, validate_request
from .long_profile import ARTIFACT, CONFIGURATION, PROFILE, PROFILE_SHA256

READY, FINAL = 'qwen_long_prefill_solo_ready', 'qwen_long_prefill_solo_report'


def validate(record, index, context, first=None):
    require(context.get('stage_cut') is None, 'Solo does not admit an explicit stage cut')
    common = {'kind','schemaVersion','correctnessOnly','throughputMeasurementValid','profile',
              'profileFingerprint','promptFileSHA256','arithmeticEnvironmentSHA256'}
    fields = common | ({'verifiedModelLoaded','freshRequestStateCreated','recordedRequestFingerprint'} if index == 0 else
        {'completed','interprocessTransportUsed','physicalTransferQualified','allRequestStateRetired','modelReleased',
         'promptTokenIDsSHA256','arithmeticEnvironment','resourceAdmission','execution','memory'})
    require(type(record) is dict and set(record) == fields, 'Unexpected long solo record fields')
    known = dict(kind=READY if index == 0 else FINAL, schemaVersion=1, profile=PROFILE,
        profileFingerprint=PROFILE_SHA256, promptFileSHA256=context['prompt_file_sha256'],
        arithmeticEnvironmentSHA256=digest(canonical(environment_receipt())))
    for key, value in known.items(): exact(record[key], value, 'Solo identity differs: ' + key)
    flags(record, correctnessOnly=True, throughputMeasurementValid=False)
    if index == 0:
        flags(record, verifiedModelLoaded=True, freshRequestStateCreated=False)
        sha(record['recordedRequestFingerprint']); return
    flags(record, completed=True, interprocessTransportUsed=False, physicalTransferQualified=False,
          allRequestStateRetired=True, modelReleased=True)
    require(first is not None, 'Solo terminal lacks loaded-ready')
    exact(record['arithmeticEnvironment'], environment_receipt(), 'Solo arithmetic receipt differs')
    exact(record['promptTokenIDsSHA256'], context['prompt_token_ids_sha256'], 'Solo prompt IDs differ')
    execution = record['execution']
    require(type(execution) is dict and type(record['resourceAdmission']) is dict and record['resourceAdmission'],
            'Missing opaque solo execution/resource evidence')
    request = execution.get('request')
    require(type(request) is dict and type(request.get('request')) is dict, 'Missing actual solo request')
    identifier = request['request'].get('requestID')
    require(type(identifier) is str, 'Missing native request UUID')
    validate_request(request, uuid.UUID(identifier).hex, context)
    exact(request['fingerprint'], first['recordedRequestFingerprint'], 'Solo ready/request identity changed')
    source = execution.get('source')
    require(type(source) is dict and source.get('artifactAggregateSHA256') == ARTIFACT
            and source.get('sourceConfigurationSHA256') == CONFIGURATION
            and source.get('arithmeticEnvironmentSHA256') == record['arithmeticEnvironmentSHA256'],
            'Solo source identity differs')
    phases = ['before_full_model_load','full_model_loaded_no_request_state',
              'full_request_retired_weights_resident','full_model_released_cache_cleared']
    require(type(record['memory']) is list and len(record['memory']) == 4, 'Solo memory phases differ')
    for row, phase in zip(record['memory'], phases):
        require(type(row) is dict and set(row) == {'phase','activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart'}
                and row['phase'] == phase, 'Solo memory phase differs')
        require(all(type(row[key]) is int and row[key] >= 0 for key in
                    ('activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart')), 'Invalid solo memory counter')
    require(record['memory'][-1]['cachedMLXBytes'] == 0, 'Solo final cache was not cleared')
