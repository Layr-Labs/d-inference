"""Fixed cut12 plan identities from the independent pure Plan control.

No arrays, model payloads, candidate values or numerical comparisons are read.
The same selected plan binds the freshly produced full reference and both stages.
"""
from long_reference_inputs import is_sha256, require

STAGE_CUT = 12
SOURCE_LAYER_RANGES = ((0, 12), (12, 32))
PLAN_CONTROL_SHA256 = 'e6e062466026e921502e85159cdce293bbd6570cb4c6de6c6b4026c6bf006b89'
PLAN_CONTROL_RECEIPT_SHA256 = 'a252ab6be2a17177438b7cb5403735010c27750f558cc203add7ce1c53edcd41'
EXPECTED_METADATA_SHA256 = '3f0d18b1d47eeb1e7eadff19fd813e92a4b3b0eab12ceac2360bfc5c716fb3c3'
PLAN_SHA256 = '8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed'
SOURCE_LAYOUT_SHA256 = '112ea4bf7ef38bd40a088dd9c654f77607a01c2bb0f37750ea901c2adfddcf94'
STAGE_PLAN_SHA256 = ('5d038414a2230a28246d4bb6d5b62e5d4859f2cc7a415dcd60349db851dfbd7d',
                     'd33e748ed1326bc1b6198c027a889e4fd9efa931d83cb81f5a67a36234e233e3')
STAGE_CONFIGURATION_SHA256 = ('d7412870394ac3d7959daf43687901b4ed261761b688f3f1440ad791bef6b2c7',
                              '9dfb3c7494d46287334139e15b21cf10046bdd1535eebe1a2f076a98dcd0ef00')
SOURCE_MODEL_BYTES = 5038041600


def selection_receipt():
    return dict(stage_cut=STAGE_CUT, source_layer_ranges=[list(x) for x in SOURCE_LAYER_RANGES],
        plan_sha256=PLAN_SHA256, stage_plan_sha256=list(STAGE_PLAN_SHA256),
        stage_configuration_sha256=list(STAGE_CONFIGURATION_SHA256),
        pure_plan_control_sha256=PLAN_CONTROL_SHA256,
        pure_plan_control_receipt_sha256=PLAN_CONTROL_RECEIPT_SHA256,
        independent_expected_metadata_sha256=EXPECTED_METADATA_SHA256,
        native_outer_identity_validation_only=True, independent_numerical_comparison_run=False)


def validate_reference_source(source):
    require(type(source) is dict and source.get('planSHA256') == PLAN_SHA256
        and source.get('sourceParameterLayoutSHA256') == SOURCE_LAYOUT_SHA256
        and type(source.get('layerCount')) is int and source['layerCount'] == 32
        and type(source.get('sourceModelTensorBytes')) is int
        and source['sourceModelTensorBytes'] == SOURCE_MODEL_BYTES,
        'Full reference does not bind the exact selected cut12 source plan')


def validate_selected_stages(stages, agreement):
    require(type(stages) is list and len(stages) == 2 and type(agreement) is dict,
        'Two actual selected stage receipts and agreement required')
    for rank, stage in enumerate(stages):
        require(type(stage) is dict and type(stage.get('stageIndex')) is int and stage['stageIndex'] == rank
            and stage.get('planSHA256') == PLAN_SHA256
            and stage.get('stagePlanSHA256') == STAGE_PLAN_SHA256[rank]
            and stage.get('constructionConfigurationSHA256') == STAGE_CONFIGURATION_SHA256[rank]
            and stage.get('sourceParameterLayoutSHA256') == SOURCE_LAYOUT_SHA256
            and type(stage.get('sourceModelTensorBytes')) is int
            and stage['sourceModelTensorBytes'] == SOURCE_MODEL_BYTES,
            'Actual stage differs from the selected cut12 plan/configuration')
    expected = dict(planFingerprint=PLAN_SHA256, producerStageFingerprint=STAGE_PLAN_SHA256[0],
        consumerStageFingerprint=STAGE_PLAN_SHA256[1],
        producerConstructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[0],
        consumerConstructionConfigurationSHA256=STAGE_CONFIGURATION_SHA256[1])
    require(all(agreement.get(key) == value for key, value in expected.items()),
        'Comparison agreement differs from the selected cut12 plan/configuration')
    storage = agreement.get('storageCommitmentSHA256')
    require(is_sha256(storage) and all(stage.get('storageCommitmentSHA256') == storage for stage in stages),
        'Selected stage receipts and agreement disagree on their observed storage commitment')
