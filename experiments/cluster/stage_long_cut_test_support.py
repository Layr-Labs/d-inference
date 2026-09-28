"""Synthetic rank envelopes with independently recorded cut12 source constants."""
from runtime.stage_checks.common import canonical, digest
from stage_long_test_support import context, rows

PLAN = '8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed'
STAGES = ('5d038414a2230a28246d4bb6d5b62e5d4859f2cc7a415dcd60349db851dfbd7d',
          'd33e748ed1326bc1b6198c027a889e4fd9efa931d83cb81f5a67a36234e233e3')
CONFIGURATIONS = ('d7412870394ac3d7959daf43687901b4ed261761b688f3f1440ad791bef6b2c7',
                  '9dfb3c7494d46287334139e15b21cf10046bdd1535eebe1a2f076a98dcd0ef00')
LAYOUT = '112ea4bf7ef38bd40a088dd9c654f77607a01c2bb0f37750ea901c2adfddcf94'
HOSTS = [['127.0.0.1:31001'], ['127.0.0.1:31002']]


def selected_context():
    return dict(context(), stage_cut=12)


def selected_rows(rank=0, ctx=None):
    ctx = ctx or selected_context(); values = rows(rank, ctx)
    for value in values:
        agreement = value['agreement']
        agreement.update(planFingerprint=PLAN, producerStageFingerprint=STAGES[0], consumerStageFingerprint=STAGES[1],
            producerConstructionConfigurationSHA256=CONFIGURATIONS[0], consumerConstructionConfigurationSHA256=CONFIGURATIONS[1])
        value['agreementFingerprint'] = digest(b'qwen-profiled-prefill-start-agreement-v1\n' + canonical(agreement))
    values[1]['sourceLoad'].update(planSHA256=PLAN, stagePlanSHA256=STAGES[rank],
        constructionConfigurationSHA256=CONFIGURATIONS[rank], sourceParameterLayoutSHA256=LAYOUT,
        sourceModelTensorBytes=5038041600)
    return values
