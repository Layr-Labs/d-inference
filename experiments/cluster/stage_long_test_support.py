"""Fabricated long-profile metadata and process handles; no native execution."""
import copy
from pathlib import Path
from runtime.stage_checks.common import canonical, digest
from runtime.stage_checks.long_identity import environment_receipt, known_agreement, recorded_request
from runtime.stage_checks.long_profile import ARTIFACT, CONFIGURATION, PROFILE, PROFILE_SHA256
from runtime.stage_checks.long_stream import WARNING

EPOCH = 'a' * 32


def context(mode='long-prefill-ranks'):
    prompt = [3] * 8192; raw = canonical(prompt) + b'\n'
    return dict(mode=mode, epoch=EPOCH, model='/unused-model', artifact=ARTIFACT,
        configuration_sha256=CONFIGURATION, prompt=prompt, prompt_file_sha256=digest(raw),
        prompt_token_ids_sha256=digest(','.join(map(str, prompt)).encode()),
        stage_prefill_policy='serial_v1' if mode == 'long-prefill-ranks' else None,
        stage_logits_dtype='bfloat16' if mode == 'long-prefill-ranks' else None)


def memory(phases):
    return [dict(phase=phase, activeMLXBytes=1, cachedMLXBytes=0, peakMLXBytesSinceProcessStart=1) for phase in phases]


def rows(rank=0, ctx=None):
    ctx = ctx or context(); env = environment_receipt(); env_sha = digest(canonical(env))
    request = recorded_request(ctx['epoch'], ctx['prompt'])
    if ctx['mode'] == 'long-prefill-ranks':
        agreement = known_agreement(ctx['epoch'], ctx['stage_prefill_policy'], ctx)
        for key in ('storageCommitmentSHA256','planFingerprint','producerStageFingerprint','consumerStageFingerprint',
                    'producerConstructionConfigurationSHA256','consumerConstructionConfigurationSHA256'):
            agreement[key] = 'b' * 64
        common = dict(schemaVersion=1, epoch=ctx['epoch'], rank=rank, worldSize=2, transport='loopback-test',
            backend='ring', flow='profiled_prefill_measurement_v1', envelopeVersion=4, agreement=agreement,
            agreementFingerprint=digest(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(agreement)),
            promptFileSHA256=ctx['prompt_file_sha256'])
        ready = dict(common, kind='qwen_long_prefill_rank_ready', modelsReadyAgreementValidated=True, freshRequestStateCreated=False)
        final = dict(common, kind='qwen_long_prefill_rank_report', completed=True, correctnessOnly=True,
            throughputMeasurementValid=False, modelForwardCompared=False, physicalTransferQualified=False,
            sourceLoad=dict(schemaVersion=1, stageIndex=rank, verifiedAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIGURATION,
                storageCommitmentSHA256=agreement['storageCommitmentSHA256'], bf16ConversionEnabled=True,
                embeddingActivationDType='bfloat16', planSHA256=agreement['planFingerprint'],
                stagePlanSHA256=agreement['producerStageFingerprint' if rank == 0 else 'consumerStageFingerprint'],
                constructionConfigurationSHA256=agreement['producerConstructionConfigurationSHA256' if rank == 0
                                                         else 'consumerConstructionConfigurationSHA256']),
            request=request, arithmeticEnvironment=env, arithmeticEnvironmentSHA256=env_sha,
            resourceAdmission={'synthetic':True}, execution={'synthetic':True}, allRequestStateRetired=True, modelReleased=True,
            memory=memory(['before_stage_load','stage_loaded_no_request_state','stage_request_retired_weights_resident',
                           'stage_model_released_cache_cleared']))
    else:
        common = dict(schemaVersion=1, correctnessOnly=True, throughputMeasurementValid=False, profile=PROFILE,
            profileFingerprint=PROFILE_SHA256, promptFileSHA256=ctx['prompt_file_sha256'], arithmeticEnvironmentSHA256=env_sha)
        ready = dict(common, kind='qwen_long_prefill_solo_ready', verifiedModelLoaded=True, freshRequestStateCreated=False,
                     recordedRequestFingerprint=request['fingerprint'])
        final = dict(common, kind='qwen_long_prefill_solo_report', completed=True, interprocessTransportUsed=False,
            physicalTransferQualified=False, allRequestStateRetired=True, modelReleased=True,
            promptTokenIDsSHA256=ctx['prompt_token_ids_sha256'], arithmeticEnvironment=env, resourceAdmission={'synthetic':True},
            execution=dict(request=request, source=dict(artifactAggregateSHA256=ARTIFACT,
                sourceConfigurationSHA256=CONFIGURATION, arithmeticEnvironmentSHA256=env_sha), synthetic=True),
            memory=memory(['before_full_model_load','full_model_loaded_no_request_state',
                           'full_request_retired_weights_resident','full_model_released_cache_cleared']))
    return copy.deepcopy([ready, final])


def write_rows(directory, values, paired=True):
    path = Path(directory)
    (path / 'stdout.jsonl').write_bytes(b''.join(canonical(value) + b'\n' for value in values))
    (path / 'stderr.log').write_bytes(WARNING if paired else b'')


class Clock:
    def __init__(self): self.now = 0.0
    def __call__(self): return self.now
    def sleep(self, value): self.now += value


class Child:
    def __init__(self, rank, clock, finish=.1, code=0):
        self.pid, self.clock, self.finish, self.code, self.waits = 1000 + rank, clock, finish, code, 0
    def poll(self): return self.code if self.clock() >= self.finish else None
    def wait(self, timeout):
        if self.poll() is None: raise TimeoutError('Fake child still active')
        self.waits += 1; return self.code
