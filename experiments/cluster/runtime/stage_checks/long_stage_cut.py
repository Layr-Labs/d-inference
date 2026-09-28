"""Registered long-stage selections; native Plan owns the fingerprints below."""
from . import stage_ranges
from .common import integer, require
from .long_profile import ARTIFACT, CONFIGURATION

# Eligibility is separate from geometry: add a descriptor/policy only after
# its native and independent CPU qualification. No Python Plan serializer.
_SELECTIONS = {
    12: dict(
        policies=('serial_v1',), ranges=((0, 12), (12, 32)),
        plan='8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed',
        stages=('5d038414a2230a28246d4bb6d5b62e5d4859f2cc7a415dcd60349db851dfbd7d',
                'd33e748ed1326bc1b6198c027a889e4fd9efa931d83cb81f5a67a36234e233e3'),
        configurations=('d7412870394ac3d7959daf43687901b4ed261761b688f3f1440ad791bef6b2c7',
                        '9dfb3c7494d46287334139e15b21cf10046bdd1535eebe1a2f076a98dcd0ef00')),
}
_TEXT_GEOMETRY = dict(num_hidden_layers=32, full_attention_interval=4)
_SOURCE_LAYOUT = '112ea4bf7ef38bd40a088dd9c654f77607a01c2bb0f37750ea901c2adfddcf94'


def option(command, cut, policy):
    if cut is None: return None
    require(command == 'long-prefill-ranks', 'Explicit long stage cuts require long-prefill-ranks')
    integer(cut, 1, 127)
    require(cut in _SELECTIONS, 'Long stage cut has no admitted registered descriptor')
    selected = _SELECTIONS[cut]
    require(stage_ranges.ranges(_TEXT_GEOMETRY, cut) == selected['ranges'], 'Registered stage geometry differs')
    require(type(policy) is str and policy in selected['policies'], 'Scheduling policy is not admitted for this long stage cut')
    return cut


def requested(args):
    return option(args.command, getattr(args, 'stage_cut', None), getattr(args, 'stage_prefill_policy', None))


def for_context(context):
    cut = option(context.get('mode'), context.get('stage_cut'), context.get('stage_prefill_policy'))
    if cut is not None:
        require(context.get('artifact') == ARTIFACT and context.get('configuration_sha256') == CONFIGURATION,
                'Selected long stage requires the registered source/configuration')
    return cut


def agreement_fields(context):
    cut = for_context(context)
    if cut is None: return {}
    selected = _SELECTIONS[cut]
    return dict(planFingerprint=selected['plan'], producerStageFingerprint=selected['stages'][0],
        consumerStageFingerprint=selected['stages'][1],
        producerConstructionConfigurationSHA256=selected['configurations'][0],
        consumerConstructionConfigurationSHA256=selected['configurations'][1])


def source_fields(context):
    if for_context(context) is None: return {}
    # Existing contract loops also bind each local stage/config to its agreement.
    return dict(sourceParameterLayoutSHA256=_SOURCE_LAYOUT, sourceModelTensorBytes=5038041600)


def receipt(context):
    cut = for_context(context)
    require(cut is not None, 'No explicit long stage selection')
    selected = _SELECTIONS[cut]
    return dict(stage_cut=cut, source_layer_ranges=[list(row) for row in selected['ranges']],
        plan_sha256=selected['plan'], stage_plan_sha256=list(selected['stages']),
        stage_configuration_sha256=list(selected['configurations']),
        source_identity_validation_only=True, independent_numerical_action_timing_audit_performed=False)
