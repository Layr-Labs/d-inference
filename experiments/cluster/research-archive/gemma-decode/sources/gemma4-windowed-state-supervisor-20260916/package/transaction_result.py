"""Closed result and build identity for the actual CBv2 native-array fixture."""
from binding_common import parse, require, same

EXPECTED = dict(passed=['keep-0', 'keep-1', 'keep-2', 'progressive-stop',
    'progressive-continue', 'open-binding-failure-retired', 'evaluated-failure-retired'],
    fabricatedNativeArrays=True, modelExecution=False, bilateralVerification=False)


def validate_result(raw):
    require(type(raw) is bytes and 0 < len(raw) <= 16384, 'Native result exceeds its exact bound')
    value = parse(raw)
    same(value, EXPECTED, 'Native transaction result')
    return value
