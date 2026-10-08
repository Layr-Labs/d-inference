"""Fabricated CPU-only DTO/input fixtures; no import-time filesystem reads."""
import copy
from contextlib import contextmanager
import hashlib
import json
from unittest.mock import patch
import long_reference_inputs as source
from short_cut_request import recorded_request, expected_source
from short_cut_expected import (PLAN_SHA256, SOURCE_LAYOUT_SHA256, SOURCE_MODEL_BYTES,
                               STAGE_PLAN_SHA256, STAGE_CONFIGURATION_SHA256, NAMED_STATE_AND_BOUNDARY_BYTES)

RUN_ID = 'b' * 32
PROMPT = [3 + (index * 17 % 500) for index in range(65)]
TEACHER = [4087, 13, 271]
RAW_PROMPT = json.dumps(PROMPT, indent=1).encode() + b'\n'
RAW_TEACHER = b'[4087, 13, 271]\n'
PREFIX = PROMPT + list(range(31))
RAW_PREFIX = json.dumps(PREFIX).encode()
RAW_TEXT = b'Fabricated CPU fixture; not an actual model prompt.\n'
sha = lambda raw: hashlib.sha256(raw).hexdigest()
PROMPT_SHA, TEACHER_SHA = sha(RAW_PROMPT), sha(RAW_TEACHER)
ORIGIN = dict(tokenization=dict(prompt_ids=PREFIX, source_text_sha256=sha(RAW_TEXT)),
              baseline_teacher_tokens=TEACHER,
              native_calls=[dict(name='cbv2-native', status='validated', exit_code=0,
                                 rank_evidence_sha256={'rank-0/teacher.json': TEACHER_SHA})])
RAW_ORIGIN = json.dumps(ORIGIN).encode()


@contextmanager
def pinned_inputs():
    with patch.multiple(source, PROMPT_SHA256=PROMPT_SHA, TEACHER_SHA256=TEACHER_SHA,
                        ORIGIN_SHA256=sha(RAW_ORIGIN), PREFIX96_SHA256=sha(RAW_PREFIX), SOURCE_TEXT_SHA256=sha(RAW_TEXT)):
        yield


def inputs():
    return dict(prompt=PROMPT, teacher=TEACHER, prompt_file_sha256=PROMPT_SHA, teacher_file_sha256=TEACHER_SHA)


def rows():
    request = recorded_request('abcdef01-2345-6789-abcd-ef0123456789', inputs())
    source_identity = expected_source()
    def memory(phase):
        return dict(phase=phase, activeMLXBytes=16, cachedMLXBytes=0, peakMLXBytesSinceProcessStart=32)
    memories = [memory(p) for p in ['before_baseline_load', 'baseline_released_cache_cleared',
        'both_stages_loaded', 'stage_requests_retired', 'stage_models_released_cache_cleared']]
    # Numerical frame contents intentionally opaque to these OUTER-only fixtures.
    baseline = dict(kind='qwen_layer_stage_recorded_baseline', correctnessOnly=True, throughputMeasurementValid=False,
        request=request, source=source_identity, frames=[{} for _ in range(6)], fingerprint='a' * 64, allRequestStateRetired=True)
    checkpoint = dict(kind='qwen_layer_stage_baseline_checkpoint', baselineModelReleasedBeforeStageLoading=True,
                      baseline=baseline, memory=copy.deepcopy(memories[:2]))
    compared = dict(kind='qwen_layer_stage_recorded_comparison', correctnessOnly=True, throughputMeasurementValid=False,
        sequentialOneProcessOnly=True, nativeBoundaryBytesCopied=True, baselineEvidenceSHA256=baseline['fingerprint'],
        requestSHA256=request['fingerprint'], source=copy.deepcopy(source_identity), stageStorageCommitmentSHA256='c' * 64,
        frames=[{} for _ in range(6)], allRequestStateRetired=True)
    loads = [dict(schemaVersion=1, stageIndex=i, verifiedAggregateSHA256=source.ARTIFACT,
        sourceConfigurationSHA256=source.CONFIGURATION, sourceParameterLayoutSHA256=SOURCE_LAYOUT_SHA256,
        sourceModelTensorBytes=SOURCE_MODEL_BYTES, planSHA256=PLAN_SHA256, stagePlanSHA256=STAGE_PLAN_SHA256[i],
        constructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[i], embeddingActivationDType='bfloat16',
        bf16ConversionEnabled=True, storageCommitmentSHA256='c' * 64) for i in range(2)]
    final = dict(kind='qwen_layer_stage_comparison_report', correctnessOnly=True, throughputMeasurementValid=False,
        baselineModelReleasedBeforeStageLoading=True, stageModelsReleasedAfterComparison=True,
        conservativeStateAndBoundaryBytes=NAMED_STATE_AND_BOUNDARY_BYTES, stageLoads=loads,
        comparison=compared, memory=memories)
    return [checkpoint, final]


class Child:
    pid = 43210
    def __init__(self, code): self.code, self.waits = code, 0
    def poll(self): return self.code
    def wait(self, timeout=0): self.waits += 1; return self.code
