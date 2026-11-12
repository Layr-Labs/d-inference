"""Closed source/plan correlation, independent of sidecar events or timings."""
import json
from sidecar_files import require

ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b'
CONFIGURATION = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
PLAN = '8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed'
LAYOUT = '112ea4bf7ef38bd40a088dd9c654f77607a01c2bb0f37750ea901c2adfddcf94'
STAGES = ['5d038414a2230a28246d4bb6d5b62e5d4859f2cc7a415dcd60349db851dfbd7d',
          'd33e748ed1326bc1b6198c027a889e4fd9efa931d83cb81f5a67a36234e233e3']
CONFIGURATIONS = ['d7412870394ac3d7959daf43687901b4ed261761b688f3f1440ad791bef6b2c7',
                  '9dfb3c7494d46287334139e15b21cf10046bdd1535eebe1a2f076a98dcd0ef00']
SELECTION = dict(stage_cut=12, source_layer_ranges=[[0,12],[12,32]], plan_sha256=PLAN,
    stage_plan_sha256=STAGES, stage_configuration_sha256=CONFIGURATIONS,
    pure_plan_control_sha256='e6e062466026e921502e85159cdce293bbd6570cb4c6de6c6b4026c6bf006b89',
    pure_plan_control_receipt_sha256='a252ab6be2a17177438b7cb5403735010c27750f558cc203add7ce1c53edcd41',
    independent_expected_metadata_sha256='3f0d18b1d47eeb1e7eadff19fd813e92a4b3b0eab12ceac2360bfc5c716fb3c3',
    native_outer_identity_validation_only=True, independent_numerical_comparison_run=False)


def canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)


def fields(actual, expected):
    require(type(actual) is dict and all(type(actual.get(key)) is type(value) and actual[key] == value
            for key,value in expected.items()), 'Selected cut12 source/plan fields differ')


def validate_receipt_selection(receipt):
    selected=receipt.get('selected_layer_plan')
    require(type(selected) is dict and canonical(selected) == canonical(SELECTION),
            'Exact cut12 selected layer plan receipt required')
    fields(receipt,dict(artifact_aggregate_sha256=ARTIFACT,configuration_sha256=CONFIGURATION))


def validate_native_selection(agreement, source, rank):
    require(type(rank) is int and rank in (0,1), 'Selected source rank is invalid')
    fields(agreement,dict(planFingerprint=PLAN,producerStageFingerprint=STAGES[0],consumerStageFingerprint=STAGES[1],
        producerConstructionConfigurationSHA256=CONFIGURATIONS[0],consumerConstructionConfigurationSHA256=CONFIGURATIONS[1],
        artifactAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION))
    fields(source,dict(stageIndex=rank,planSHA256=PLAN,stagePlanSHA256=STAGES[rank],
        constructionConfigurationSHA256=CONFIGURATIONS[rank],sourceParameterLayoutSHA256=LAYOUT,
        sourceModelTensorBytes=5038041600,verifiedAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION))
