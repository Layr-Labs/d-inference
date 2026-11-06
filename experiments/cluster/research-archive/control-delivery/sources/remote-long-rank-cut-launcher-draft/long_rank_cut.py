"""Selected cut12 plan admission only; arrays, state, timing and wire audit are separate."""
from long_reference_inputs import is_sha256, require
from long_pair_cut import PLAN_SHA256, SOURCE_LAYOUT_SHA256, SOURCE_MODEL_BYTES
from long_pair_cut import STAGE_PLAN_SHA256, STAGE_CONFIGURATION_SHA256


def validate_agreement(value):
    expected = dict(planFingerprint=PLAN_SHA256, producerStageFingerprint=STAGE_PLAN_SHA256[0],
        consumerStageFingerprint=STAGE_PLAN_SHA256[1],
        producerConstructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[0],
        consumerConstructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[1])
    require(type(value) is dict and all(value.get(key) == item for key, item in expected.items()),
        'Rank agreement differs from the exact selected cut12 plan/configuration')


def validate_source(source, rank, agreement):
    require(type(rank) is int and rank in (0, 1), 'Invalid selected stage rank')
    validate_agreement(agreement)
    require(type(source) is dict and type(source.get('stageIndex')) is int and source['stageIndex'] == rank
        and source.get('planSHA256') == PLAN_SHA256
        and source.get('stagePlanSHA256') == STAGE_PLAN_SHA256[rank]
        and source.get('constructionConfigurationSHA256') == STAGE_CONFIGURATION_SHA256[rank]
        and source.get('sourceParameterLayoutSHA256') == SOURCE_LAYOUT_SHA256
        and type(source.get('sourceModelTensorBytes')) is int and source['sourceModelTensorBytes'] == SOURCE_MODEL_BYTES,
        'Actual local source differs from the selected cut12 stage/configuration')
    storage = agreement.get('storageCommitmentSHA256')
    require(is_sha256(storage) and source.get('storageCommitmentSHA256') == storage,
        'Selected local source and agreement have different observed storage commitments')
