"""Independent stdlib-only v2 envelope/ACK vectors and bounded JSON checks."""
import base64
import hashlib
import json
import re
import struct
from pathlib import Path

FLOW = 'prompt_lookahead_one_v1'
PHASES = ('ready', 'received', 'consumed')
LIMIT = 16 * 1024


def require(ok, message):
    if not ok: raise ValueError(message)


def sha(data): return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def strict_json(data):
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate decoded JSON key')
            result[key] = value
        return result
    def integer(value):
        require(len(value) <= 20, 'Integer lexeme too long')
        return int(value)
    try:
        return json.loads(data.decode('utf-8'), object_pairs_hook=unique, parse_int=integer,
            parse_float=lambda _: require(False, 'Fraction/exponent number lexeme'),
            parse_constant=lambda _: require(False, 'Nonfinite JSON'))
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError('Malformed JSON') from error


def exact(actual, expected):
    require(type(actual) is type(expected), 'Field JSON type differs')
    if isinstance(expected, dict):
        require(set(actual) == set(expected), 'Closed field schema differs')
        for key in expected: exact(actual[key], expected[key])
    elif isinstance(expected, list):
        require(len(actual) == len(expected), 'Field list length differs')
        for left, right in zip(actual, expected): exact(left, right)
    else: require(actual == expected, 'Local expectation differs')


def decode(data, expected_boundary):
    """Return the admitted nested header; caller retains original data for ACKs."""
    require(type(data) is bytes and 0 < len(data) <= LIMIT, 'Envelope byte bound')
    depth, quoted, escaped = 0, False, False
    for byte in data:
        if quoted:
            if escaped: escaped = False
            elif byte == 92: escaped = True
            elif byte == 34: quoted = False
        elif byte == 34: quoted = True
        elif byte in (123, 91):
            depth += 1
            require(depth <= 65, 'JSON depth limit')
        elif byte in (125, 93): depth -= 1
    outer = strict_json(data)
    require(type(outer) is dict and set(outer) == {'version', 'flow', 'boundary'}, 'Closed outer schema differs')
    exact(outer['version'], 2); exact(outer['flow'], FLOW)
    nested = outer['boundary']
    require(type(nested) is dict and set(nested) == set(expected_boundary), 'Closed nested schema differs')
    require(type(nested['payloadSHA256']) is str and re.fullmatch('[0-9a-f]{64}', nested['payloadSHA256']), 'Invalid payload digest')
    exact({key: value for key, value in nested.items() if key != 'payloadSHA256'},
        {key: value for key, value in expected_boundary.items() if key != 'payloadSHA256'})
    return nested


def ack_values(data, phase, expected_boundary):
    decode(data, expected_boundary)
    require(phase in PHASES, 'Invalid ACK phase')
    return list(sha(f'qwen-stage-ack-v2|{FLOW}|{phase}|{sha(data)}'.encode()).encode())


def validate_ack(actual, data, phase, expected_boundary):
    exact(actual, ack_values(data, phase, expected_boundary))


def frames():
    return [dict(sequence=index, phase='prefill' if index < 3 else 'decode',
        tokenOffset=offset, tokenCount=count, finalPromptChunk=index == 2)
        for index, (offset, count) in enumerate([(0, 32), (32, 32), (64, 1), (65, 1), (66, 1), (67, 1)])]


def boundary(frame, dtype):
    byte_count = frame['tokenCount'] * 128 * (4 if dtype == 'float32' else 2)
    return dict(version=1,
        requestFingerprint=sha(b'qwen-stage-request-v1|00000000-0000-0000-0000-000000000001|65|32|4'),
        sourceConfigurationSHA256='a' * 64, artifactAggregateSHA256='b' * 64,
        storageCommitmentSHA256='c' * 64, planFingerprint='d' * 64, producerStageFingerprint='e' * 64,
        frame=frame, tokenIDsSHA256=sha(','.join(['7'] * frame['tokenCount']).encode()),
        payloadSHA256=sha(bytes([19]) * byte_count), shape=[1, frame['tokenCount'], 128], dtype=dtype, byteCount=byte_count)


def encoded(header): return canonical(dict(version=2, flow=FLOW, boundary=header))


def cases():
    output = []
    for dtype in ('bfloat16', 'float16', 'float32'):
        for frame in frames():
            header = boundary(frame, dtype)
            output.append(('canonical', header, encoded(header)))
    header = boundary(frames()[0], 'bfloat16'); data = encoded(header)
    output.extend([('surrounding_whitespace', header, b' \n' + data + b'\t'),
        ('integer_negative_zero', header, data.replace(b'"tokenOffset":0', b'"tokenOffset":-0')),
        ('exact_byte_limit', header, data + b' ' * (LIMIT - len(data)))])
    return output


def check_vectors(path):
    data = Path(path).read_bytes()
    require(0 < len(data) <= 1024**2, 'Harness stdout bound')
    lines = data.splitlines(); require(len(lines) == 2, 'Expected v1/v2 selfcheck records')
    old, new = [strict_json(line) for line in lines]
    exact(old, dict(kind='qwen_layer_stage_boundary_wire_check', cpuOnly=True, acceptedFrames=6, rejectedFixtures=44))
    require(set(new) == {'kind', 'cpuOnly', 'flow', 'acceptedEnvelopeCases', 'rejectedFixtures', 'rejectionLabels', 'vectors'},
        'New selfcheck schema differs')
    exact({key: new[key] for key in ['kind', 'cpuOnly', 'flow', 'acceptedEnvelopeCases', 'rejectedFixtures']},
        dict(kind='qwen_layer_stage_lookahead_wire_check', cpuOnly=True, flow=FLOW, acceptedEnvelopeCases=21, rejectedFixtures=70))
    require(len(new['rejectionLabels']) == len(set(new['rejectionLabels'])) == 70, 'Swift rejection coverage differs')
    require(type(new['vectors']) is list and len(new['vectors']) == 21, 'Envelope vector coverage differs')
    output = []
    for record, (variant, header, wire) in zip(new['vectors'], cases()):
        decoded = decode(wire, header); exact(decoded, header)
        acknowledgements = []
        for phase in PHASES:
            values = ack_values(wire, phase, header)
            acknowledgements.append(dict(phase=phase, values=values, logicalBytesSHA256=sha(struct.pack('<64i', *values))))
        expected = dict(variant=variant, frame=header['frame'], dtype=header['dtype'], payloadByteCount=header['byteCount'],
            innerBase64=base64.b64encode(canonical(header)).decode(), outerBase64=base64.b64encode(wire).decode(),
            outerSHA256=sha(wire), acknowledgements=acknowledgements)
        exact(record, expected)
        output.append(dict(variant=variant, frameSequence=header['frame']['sequence'], dtype=header['dtype'],
            outerByteCount=len(wire), outerSHA256=sha(wire), ackLogicalBytesSHA256=[x['logicalBytesSHA256'] for x in acknowledgements]))
    return dict(status='passed', cpuOnly=True, flow=FLOW, envelopeVectors=21, ACKVectors=63,
        oldV1Accepted=6, oldV1Rejected=44, swiftV2Accepted=21, swiftV2Rejected=70,
        stdoutSHA256=sha(data), independentlyGeneratedVectorHashes=output,
        inferenceBuild=False, MLXImports=False, transportOperations=0, modelReads=0)


if __name__ == '__main__':
    import sys
    print(json.dumps(check_vectors(sys.argv[1]), sort_keys=True))
