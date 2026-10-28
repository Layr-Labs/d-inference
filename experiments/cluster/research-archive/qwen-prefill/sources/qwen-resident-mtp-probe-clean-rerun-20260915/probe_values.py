"""Exact extracted value/identity helpers; see helper-lineage.json."""
import hashlib
import json
import re
import uuid

def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def parse_json(text):
    """Preserve Swift JSONEncoder's integer spelling -0 as floating negative zero."""
    def unique(items):
        out = {}
        for key, value in items:
            require(key not in out, 'Duplicate JSON key')
            out[key] = value
        return out
    return json.loads(text, object_pairs_hook=unique,
        parse_int=lambda value: -0.0 if value == '-0' else int(value),
        parse_constant=lambda _: require(False, 'Nonfinite JSON'))


VOCAB = 248320


PROMPT = 8192


OUTPUT = 128


CHUNK = 512


ARTIFACT = '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64' '291f521f051469b7c24b'


CONFIG = 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423'


PLAN = '67bf0b1bf94f229682df58ae1ae10c758e2a386d66d3e1b68146f5c090f6309f'


ARITHMETIC = '0ae9c7c21048fa94fc90353b84cd8578f4adc05b1b22c3d55bd70f01c9c3bc74'


STAGES = ['7d5ebf4cec108854b7a5375a208301ca58d00a33d1fb8ef3e3bb59923f482f0a',
          '7b362c5c14e45c17ce1327bc23179dc58b61f8d6a96ca2bc5752976f9fe53264']


CONSTRUCTIONS = ['54e01cdceaea0fba5033e1378f4d534a73aae30a56cf052548b7f03fa3b23d72',
                 '2b5acaba48a06190b6a4268a8b0ef9f3475318057ab275277f57f3c02dfe6582']


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


def token_hash(tokens):
    return digest(','.join(map(str, tokens)).encode())


def profile():
    identifier = 'registered_qwen35_9b_greedy_generation_v1'
    result = dict(identifier=identifier, vocabularySize=VOCAB, hiddenSize=4096,
                  activationDType='bfloat16', maximumPromptTokens=PROMPT,
                  maximumChunkTokens=CHUNK, maximumOutputTokens=OUTPUT,
                  maximumContextTokens=PROMPT + OUTPUT)
    result['fingerprint'] = digest('|'.join(['qwen-stage-generation-profile-v1', identifier,
        str(VOCAB), '4096', 'bfloat16', str(PROMPT), str(CHUNK), str(OUTPUT), str(PROMPT + OUTPUT)]).encode())
    return result


AGREEMENT_KEYS = ('schema rankCount membershipEpoch requestID requestFingerprint profileFingerprint '
    'sourceConfigurationSHA256 artifactAggregateSHA256 storageCommitmentSHA256 planFingerprint '
    'stageFingerprints rankBuildSHA256 numericalPolicySHA256 mtpEnabled')


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
        numericalPolicySHA256=value['numericalPolicySHA256'], mtpEnabled=False)
    exact(value, expected, 'expected agreement')
    return digest(b'qwen-stage-generation-v1|agreement|' + canonical(value))

