"""Closed result and build identity for the actual CBv2 native-array fixture."""
from binding_common import parse, require, same

REMOTE = '/Users/developer/DarkbloomDev/qwen-target-verification-check-20260915'
NATIVE = '2291d742aea5b66f459fd3b86af8ed89015a027049029884b902348ec6369840'
BUNDLE = 'fba584e9519feb3451fd21f654a3afb602b2e6088c75d43037425e2a164259a9'
SOURCE = '1962591fdc66bda64459988a92af51f9b6b33ca6570385b68a3104f277a2942c'
METALLIB = '2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2'
PAGED = '4ad3ff17d8c6e0a3b5b8a91e9151447f84e36cb3688ed204e1e7eb6838dd9149'
EXPECTED = dict(passed=['keep-0', 'keep-1', 'keep-2', 'progressive-stop',
    'progressive-continue', 'open-binding-failure-retired', 'evaluated-failure-retired'],
    fabricatedNativeArrays=True, modelExecution=False, bilateralVerification=False)


def validate_result(raw):
    require(type(raw) is bytes and 0 < len(raw) <= 16384, 'Native result exceeds its exact bound')
    value = parse(raw)
    same(value, EXPECTED, 'Native transaction result')
    return value
