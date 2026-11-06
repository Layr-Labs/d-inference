"""Invented CPU values only; never a model result or tokenization claim."""
import hashlib
from long_reference_inputs import ARTIFACT, CONFIGURATION, PROFILE, PROFILE_SHA256

PROMPT = [3] * 8192
RAW_PROMPT = ('[ ' + ', '.join(map(str, PROMPT)) + ' ]\n').encode()
PROMPT_SHA = hashlib.sha256(RAW_PROMPT).hexdigest()
LOGICAL_SHA = hashlib.sha256(','.join(map(str, PROMPT)).encode()).hexdigest()
RUN_ID = 'a' * 32


def inputs():
    return dict(prompt=PROMPT[:], prompt_file_sha256=PROMPT_SHA,
                prompt_token_ids_sha256=LOGICAL_SHA)


def rows():
    first = dict(kind='qwen_long_prefill_reference_ready', schemaVersion=1,
        correctnessOnly=True, throughputMeasurementValid=False, verifiedModelLoaded=False,
        freshRequestStateCreated=False, profile=PROFILE, profileFingerprint=PROFILE_SHA256,
        promptFileSHA256=PROMPT_SHA, arithmeticEnvironmentSHA256='b' * 64,
        recordedRequestFingerprint='c' * 64)
    evidence = {key: first[key] for key in ('profile', 'profileFingerprint', 'promptFileSHA256', 'arithmeticEnvironmentSHA256')}
    evidence.update(promptTokenIDsSHA256=LOGICAL_SHA,
        execution=dict(request=dict(fingerprint='c' * 64), source=dict(artifactAggregateSHA256=ARTIFACT,
            sourceConfigurationSHA256=CONFIGURATION), deliberatelyOpaque=True))
    final = dict(kind='qwen_long_prefill_reference_report', schemaVersion=1,
        completed=True, correctnessOnly=True, throughputMeasurementValid=False,
        interprocessTransportUsed=False, physicalTransferQualified=False,
        allRequestStateRetired=True, modelReleased=True, evidence=evidence,
        memory=[dict(phase=phase, activeMLXBytes=0, cachedMLXBytes=0, peakMLXBytesSinceProcessStart=0)
                for phase in ('before_full_model_load', 'full_model_released_cache_cleared')])
    return [first, final]


class Child:
    pid = 7001
    def __init__(self, code):
        self.code, self.waits = code, 0
    def poll(self):
        return self.code
    def wait(self, timeout=None):
        self.waits += 1
        return self.code
