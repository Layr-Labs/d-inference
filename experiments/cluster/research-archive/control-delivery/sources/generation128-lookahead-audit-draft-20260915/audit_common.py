"""Closed registered9B / cut4 / 8192+128 lookahead diagnostic identities."""
import math
import re
import uuid
from recorded_math import canonical, digest, parse_json, require

VOCAB = 248320
PROMPT = 8192
OUTPUT = 128
CHUNK = 512
FRONTIER = PROMPT + OUTPUT - 1
FRAMES = PROMPT // CHUNK + OUTPUT - 1
ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64' '291f521f051469b7c24b'
CONFIG = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'
MANIFEST = '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4'
LAYOUT = '112ea4bf7ef38bd40a088dd9c654f77607a01c2bb0f37750ea901c2adfddcf94'
PLAN = '67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f'
ARITHMETIC = '0ae9c7c21048fa94fc90353b84cd8578f4adc05b1b22c3d55bd70f01c9c3bc74'
STAGES = ['7d5ebf4cec108854b7a5375a208301ca58d00a33d1fb8ef3e3bb59923f482f0a',
          '7b362c5c14e45c17ce1327bc23179dc58b61f8d6a96ca2bc5752976f9fe53264']
CONSTRUCTIONS = ['54e01cdceaea0fba5033e1378f4d534a73aae30a56cf052548b7f03fa3b23d72',
                 '2b5acaba48a06190b6a4268a8b0ef9f3475318057ab275277f57f3c02dfe6582']
RANGES = [(0, 4), (4, 32)]
REFERENCE_SHA = '748b2d11346b3097435f83db53296c4873c3e42a261493614cbfe896883faaa3'
PROMPT_SHA = 'ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'
REQUEST_ID = '6426b803-8b80-40ba-8944-b0f4b403a3cf'


def fields(value, names, label):
    require(type(value) is dict and all(type(k) is str for k in value)
            and set(value) == set(names.split()), 'Wrong fields: ' + label)
    return value


def exact(actual, expected, label):
    # bool == int and int == float must not weaken a native integer/flag field.
    require(type(actual) is type(expected), 'Wrong type: ' + label)
    if type(expected) is dict:
        require(set(actual) == set(expected), 'Wrong fields: ' + label)
        for key in expected:
            exact(actual[key], expected[key], label + '.' + key)
    elif type(expected) is list:
        require(len(actual) == len(expected), 'Wrong length: ' + label)
        for index, value in enumerate(expected):
            exact(actual[index], value, label + '[' + str(index) + ']')
    else:
        require(actual == expected, 'Wrong value: ' + label)


def integer(value, minimum=0, maximum=2**63-1):
    require(type(value) is int and minimum <= value <= maximum, 'Integer outside native bound')
    return value


def sha(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None, 'Invalid SHA256')
    return value


def canonical_uuid(value):
    require(type(value) is str and str(uuid.UUID(value)) == value, 'UUID must be canonical lowercase')
    return value


def parse(raw):
    require(type(raw) is bytes and raw, 'Nonempty raw JSON bytes required')
    value = parse_json(raw.decode('utf-8'))
    def visit(item, depth):
        require(depth <= 64, 'JSON nesting exceeds bound')
        if type(item) is float:
            require(math.isfinite(item), 'Nonfinite JSON number')
        elif type(item) is dict:
            for child in item.values():
                visit(child, depth + 1)
        elif type(item) is list:
            for child in item:
                visit(child, depth + 1)
    visit(value, 0)
    return value


def token_hash(tokens):
    return digest(','.join(map(str, tokens)).encode())


def token_ids(value, count):
    require(type(value) is list and len(value) == count, 'Wrong token count')
    for token in value:
        integer(token, 0, VOCAB - 1)
    return value


def profile():
    identifier = 'registered_qwen35_9b_greedy_generation_v1'
    result = dict(identifier=identifier, vocabularySize=VOCAB, hiddenSize=4096,
                  activationDType='bfloat16', maximumPromptTokens=PROMPT,
                  maximumChunkTokens=CHUNK, maximumOutputTokens=OUTPUT,
                  maximumContextTokens=PROMPT + OUTPUT)
    result['fingerprint'] = digest('|'.join(['qwen-stage-generation-profile-v1', identifier,
        str(VOCAB), '4096', 'bfloat16', str(PROMPT), str(CHUNK), str(OUTPUT), str(PROMPT + OUTPUT)]).encode())
    return result


def request_context(prompt_raw, request_id):
    canonical_uuid(request_id)
    tokens = token_ids(parse(prompt_raw), PROMPT)
    token_pin = token_hash(tokens)
    fingerprint = digest('\n'.join(['qwen-stage-generation-request-v1', profile()['fingerprint'],
        request_id, 'prompt=' + token_pin, 'chunk=' + str(CHUNK), 'output=' + str(OUTPUT), 'stop=']).encode())
    return dict(request_id=request_id, fingerprint=fingerprint,
                prompt_sha=digest(prompt_raw), prompt_tokens_sha=token_pin)


def selected_frame(ordinal):
    integer(ordinal, 0, OUTPUT - 1)
    if ordinal == 0:
        return dict(sequence=15, phase='prefill', tokenOffset=7680,
                    tokenCount=CHUNK, finalPromptChunk=True)
    return dict(sequence=15 + ordinal, phase='decode', tokenOffset=PROMPT + ordinal - 1,
                tokenCount=1, finalPromptChunk=False)


AGREEMENT_KEYS = ('schema rankCount membershipEpoch requestID requestFingerprint profileFingerprint '
    'sourceConfigurationSHA256 artifactAggregateSHA256 storageCommitmentSHA256 planFingerprint '
    'stageFingerprints rankBuildSHA256 numericalPolicySHA256 mtpEnabled prefillSchedulingPolicy')


def agreement(value, context):
    fields(value, AGREEMENT_KEYS, 'expected agreement')
    canonical_uuid(value['membershipEpoch'])
    require(type(value['rankBuildSHA256']) is list and len(value['rankBuildSHA256']) == 2,
            'Two explicit expected rank build identities required')
    for pin in value['rankBuildSHA256'] + [value['storageCommitmentSHA256'], value['numericalPolicySHA256']]:
        sha(pin)
    expected = dict(schema='qwen_stage_generation_agreement_v1', rankCount=2,
        membershipEpoch=value['membershipEpoch'], requestID=context['request_id'],
        requestFingerprint=context['fingerprint'], profileFingerprint=profile()['fingerprint'],
        sourceConfigurationSHA256=CONFIG, artifactAggregateSHA256=ARTIFACT,
        storageCommitmentSHA256=value['storageCommitmentSHA256'], planFingerprint=PLAN,
        stageFingerprints=STAGES, rankBuildSHA256=value['rankBuildSHA256'],
        numericalPolicySHA256=value['numericalPolicySHA256'], mtpEnabled=False,
        prefillSchedulingPolicy='oneChunkLookahead')
    exact(value, expected, 'expected agreement')
    return digest(b'qwen-stage-generation-v1|agreement|' + canonical(value))
