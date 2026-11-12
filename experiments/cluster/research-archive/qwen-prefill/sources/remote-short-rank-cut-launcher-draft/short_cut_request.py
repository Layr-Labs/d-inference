"""Pure fixed request/source binding; numerical rows are not examined here."""
import hashlib
import json
import re
import uuid
from long_reference_inputs import ARTIFACT, CONFIGURATION, VOCABULARY, require, is_sha256
from short_cut_expected import PLAN_SHA256, SOURCE_LAYOUT_SHA256, SOURCE_MODEL_BYTES


def equal(left, right, label):
    encode = lambda value: json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)
    require(encode(left) == encode(right), label)


def steps(prompt, teacher):
    result = []
    for index, (offset, count) in enumerate(((0, 32), (32, 32), (64, 1), (65, 1), (66, 1), (67, 1))):
        frame = dict(sequence=index, phase='prefill' if index < 3 else 'decode',
                     tokenOffset=offset, tokenCount=count, finalPromptChunk=index == 2)
        result.append(dict(frame=frame, tokenIDs=prompt[offset:offset + count] if index < 3 else [teacher[index - 3]]))
    return result


def recorded_request(request_id, inputs):
    require(type(request_id) is str and re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', request_id),
            'Invalid native request UUID')
    normalized = str(uuid.UUID(request_id))
    request_hash = hashlib.sha256(('qwen-stage-request-v1|' + normalized + '|65|32|4').encode()).hexdigest()
    prompt, teacher = inputs['prompt'], inputs['teacher']
    material = '\n'.join(['qwen-layer-stage-recorded-request-v1', request_hash, 'vocabulary=' + str(VOCABULARY),
                          'prompt=' + ','.join(map(str, prompt)), 'teacher=' + ','.join(map(str, teacher))])
    return dict(request=dict(requestID=request_id, promptCount=65, chunkSize=32, outputCount=4),
                vocabularySize=VOCABULARY, promptTokenIDs=prompt, teacherTokenIDs=teacher,
                steps=steps(prompt, teacher), fingerprint=hashlib.sha256(material.encode()).hexdigest())


def validate_request(value, inputs):
    require(type(value) is dict and type(value.get('request')) is dict, 'Missing complete recorded request')
    equal(value, recorded_request(value['request'].get('requestID'), inputs), 'Native prompt/teacher/timeline differs')
    return value['fingerprint']


def expected_source():
    return dict(artifactAggregateSHA256=ARTIFACT, sourceConfigurationSHA256=CONFIGURATION,
                sourceParameterLayoutSHA256=SOURCE_LAYOUT_SHA256, planSHA256=PLAN_SHA256,
                bf16ConversionEnabled=True, embeddingActivationDType='bfloat16',
                sourceModelTensorBytes=SOURCE_MODEL_BYTES, layerCount=32, vocabularySize=VOCABULARY)
