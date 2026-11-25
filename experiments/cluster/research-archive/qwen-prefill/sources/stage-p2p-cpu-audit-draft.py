#!/usr/bin/env python3
"""Independent CPU validator for two rank stage-p2p-check JSONL outputs."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import uuid

MAX_STDOUT_BYTES = 128 * 1024
MAX_JSON_DEPTH = 12
NATIVE_DTYPES = ['float32', 'float16', 'bfloat16']
CONTROL_DTYPES = ['uint8', 'uint32', 'int32', 'float16', 'bfloat16', 'float32']
HIDDEN = [128, 4096, 8192]
WIDTH = dict(uint8=1, uint32=4, int32=4, float16=2, bfloat16=2, float32=4)
PATTERNS = {
    'uint8': [0, 255, 1, 128, 127, 42, 3, 17],
    'uint32': [0, 0xffffffff, 1, 0x80000000, 0x7fffffff, 42, 3, 17],
    'int32': [0, 0xffffffff, 1, 0x80000000, 0x7fffffff, 42, 3, 17],
    'float32': [0, 0x80000000, 0x3f800000, 0xbf800000, 0x3f000000, 0x40000000, 0x00800000, 0x3e800000],
    'float16': [0, 0x8000, 0x3c00, 0xbc00, 0x3800, 0x4000, 0x0400, 0x3400],
    'bfloat16': [0, 0x8000, 0x3f80, 0xbf80, 0x3f00, 0x4000, 0x0080, 0x3e80],
}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False, ensure_ascii=False).encode()


def fixture_bytes(dtype, count, shift=0):
    require(dtype in WIDTH and type(count) is int and 1 <= count <= 32 * 8192
        and type(shift) is int and 0 <= shift < 132, 'Fixture geometry outside bound')
    words = PATTERNS[dtype]
    pattern = b''.join(words[(i + shift) % 8].to_bytes(WIDTH[dtype], 'little') for i in range(8))
    return pattern * (count // 8) + pattern[:(count % 8) * WIDTH[dtype]]


def request_fingerprint(epoch):
    require(type(epoch) is str and re.fullmatch('[0-9a-f]{32}', epoch), 'Epoch must be canonical lowercase HEX32')
    return digest(f'qwen-stage-request-v1|{uuid.UUID(hex=epoch)}|65|32|4'.encode())


def acknowledgement(header, phase):
    require(phase in ('ready', 'consumed') and isinstance(header, bytes) and 0 < len(header) <= 16384,
        'ACK source or phase invalid')
    ascii_hex = digest(f'qwen-stage-ack-v1|{phase}|{digest(header)}'.encode()).encode()
    values = list(ascii_hex)
    return dict(values=values, logicalBytesSHA256=digest(struct.pack('<64i', *values)), byteCount=256)


def frame_schedule():
    frontiers = [32, 64, 65, 66, 67, 68]
    return [dict(sequence=i, phase='prefill' if i < 3 else 'decode',
        tokenOffset=0 if i == 0 else frontiers[i - 1],
        tokenCount=t - (0 if i == 0 else frontiers[i - 1]), finalPromptChunk=i == 2)
        for i, t in enumerate(frontiers)]


def wire_header(epoch, case_id, dtype, hidden, frame, payload):
    identity = {key: digest(f'stage-p2p-synthetic-v1|{case_id}|{field}'.encode()) for key, field in [
        ('sourceConfigurationSHA256', 'configuration'), ('artifactAggregateSHA256', 'artifact'),
        ('storageCommitmentSHA256', 'storage'), ('planFingerprint', 'plan'), ('producerStageFingerprint', 'stage-zero')]}
    tokens = [3 + ((i * 17 + 7) % 509) for i in range(frame['tokenOffset'], frame['tokenOffset'] + frame['tokenCount'])]
    header = dict(version=1, requestFingerprint=request_fingerprint(epoch), **identity, frame=frame,
        tokenIDsSHA256=digest(','.join(map(str, tokens)).encode()), payloadSHA256=digest(payload),
        shape=[1, frame['tokenCount'], hidden], dtype=dtype, byteCount=len(payload))
    encoded = canonical(header)
    require(0 < len(encoded) <= 16384, 'Expected wire header exceeds bound')
    return header, encoded


def expected_records(epoch, rank):
    """Generate metadata from fixed bytes and schedule, without observing a rank."""
    request_hash = request_fingerprint(epoch)
    require(type(rank) is int and rank in (0, 1), 'Rank must be zero or one')
    controls, cases, acknowledgements = [], [], []
    for index, dtype in enumerate(CONTROL_DTYPES + ['float32']):
        data = fixture_bytes(dtype, 6)
        noncontiguous = index == 6
        if noncontiguous:
            data = b''.join(data[i * 4:(i + 1) * 4] for i in [0, 2, 4, 1, 3, 5])
        row = dict(caseID=f'control-{index}', dtype=dtype, shape=[2, 3], byteCount=len(data),
            payloadSHA256=digest(data), noncontiguousSender=noncontiguous, nativeBytesExact=True)
        controls.append(row)
        acknowledgements.append(dict(caseID=row['caseID'], phase='consumed', **acknowledgement(canonical(row), 'consumed')))
    for dtype in NATIVE_DTYPES:
        for hidden in HIDDEN:
            case_id = f'{dtype}-h{hidden}'
            rows = []
            for frame in frame_schedule():
                payload = fixture_bytes(dtype, frame['tokenCount'] * hidden, frame['sequence'])
                header, encoded = wire_header(epoch, case_id, dtype, hidden, frame, payload)
                rows.append(dict(frame=frame, committedTokens=frame['tokenOffset'] + frame['tokenCount'],
                    byteCount=len(payload), payloadSHA256=header['payloadSHA256'], headerSHA256=digest(encoded), nativeBytesExact=True))
                for phase in ['ready', 'consumed']:
                    acknowledgements.append(dict(caseID=case_id, sequence=frame['sequence'], phase=phase,
                        **acknowledgement(encoded, phase)))
            cases.append(dict(caseID=case_id, dtype=dtype, hiddenSize=hidden,
                requestFingerprint=request_hash, frames=rows, complete=True))
    fixture = dict(version='stage-p2p-synthetic-v1', hiddenSizes=HIDDEN, prompt=65, chunk=32, outputs=4,
        patterns={dtype: digest(fixture_bytes(dtype, 8)) for dtype in CONTROL_DTYPES},
        noncontiguousOrder=[0, 2, 4, 1, 3, 5])
    identity = dict(schemaVersion=1, epoch=epoch, rank=rank, worldSize=2, transport='loopback-test', backend='ring')
    ready = dict(kind='stage_p2p_ready', **identity)
    terminal = dict(kind='stage_p2p_check', **identity, passed=True, correctnessOnly=True,
        throughputMeasurementValid=False, modelForwardCompared=False, physicalTransferQualified=False,
        fixtureFingerprint=digest(canonical(fixture)), controlCases=controls, cases=cases)
    return [ready, terminal], acknowledgements


def strict_json(line):
    require(isinstance(line, bytes) and 0 < len(line) <= MAX_STDOUT_BYTES, 'JSON record empty/oversized')
    depth, quoted, escaped = 0, False, False
    for byte in line:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (123, 91):
            depth += 1
            require(depth <= MAX_JSON_DEPTH, 'JSON nesting exceeds bound')
        elif byte in (125, 93):
            depth -= 1
            require(depth >= 0, 'Unbalanced JSON nesting')
    require(depth == 0 and not quoted, 'Unterminated JSON record')
    def unique(items):
        result = {}
        for key, value in items:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    try:
        value = json.loads(line.decode('utf-8'), object_pairs_hook=unique,
            parse_constant=lambda _: require(False, 'Nonfinite JSON'))
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError('Malformed JSON record') from error
    require(type(value) is dict, 'JSON record must be object')
    return value


def exact(actual, expected, path='record'):
    require(type(actual) is type(expected), 'Wrong JSON type at ' + path)
    if isinstance(expected, dict):
        require(set(actual) == set(expected), 'Wrong exact fields at ' + path)
        for key, value in expected.items():
            exact(actual[key], value, path + '.' + key)
    elif isinstance(expected, list):
        require(len(actual) == len(expected), 'Wrong list length at ' + path)
        for index, value in enumerate(expected):
            exact(actual[index], value, path + f'[{index}]')
    else:
        require(actual == expected, 'Fixture value/hash differs at ' + path)


def check_pair(stdout_paths, epoch):
    require(isinstance(stdout_paths, (list, tuple)) and len(stdout_paths) == 2, 'Need rank-zero and rank-one stdout paths')
    request_fingerprint(epoch)
    reports, file_hashes = [], []
    for rank, path in enumerate(stdout_paths):
        with Path(path).open('rb') as stream:
            data = stream.read(MAX_STDOUT_BYTES + 1)
        require(0 < len(data) <= MAX_STDOUT_BYTES, 'Rank stdout empty/oversized')
        lines = data.splitlines()
        require(len(lines) == 2 and all(lines), 'Expected exactly ready then terminal JSONL records')
        actual = [strict_json(line) for line in lines]
        expected, acks = expected_records(epoch, rank)
        exact(actual, expected, f'rank{rank}')
        reports.append(actual[1]); file_hashes.append(digest(data))
    exact({k: v for k, v in reports[0].items() if k != 'rank'},
        {k: v for k, v in reports[1].items() if k != 'rank'}, 'cross-rank terminal')
    controls, cases = reports[0]['controlCases'], reports[0]['cases']
    return dict(status='passed', cpuOnly=True, epoch=epoch, ranks=[0, 1], stdoutSHA256=file_hashes,
        recordsPerRank=2, controlCasesPerRank=7, residualCasesPerRank=9, residualFramesPerRank=54,
        residualPayloadBytesPerRank=sum(f['byteCount'] for c in cases for f in c['frames']),
        controlPayloadBytesPerRank=sum(c['byteCount'] for c in controls),
        fixtureFingerprint=reports[0]['fixtureFingerprint'], requestFingerprint=cases[0]['requestFingerprint'],
        independentlyDerivedTerminalSHA256=digest(canonical({k: v for k, v in reports[0].items() if k != 'rank'})),
        independentlyDerivedControlPayloadSHA256=[c['payloadSHA256'] for c in controls],
        independentlyDerivedResidualPayloadSHA256=[f['payloadSHA256'] for c in cases for f in c['frames']],
        independentlyDerivedHeaderSHA256=[f['headerSHA256'] for c in cases for f in c['frames']],
        expectedAcknowledgementCount=len(acks), expectedAcknowledgementsSHA256=digest(canonical(acks)),
        observedAcknowledgementBytesAvailable=False, observedReceivedPayloadBytesAvailable=False,
        nativeExecutionsByAudit=0, modelReadsByAudit=0,
        limitations=['CPU derives all fixture bytes and exact emitted schemas/hashes for both ranks; raw received payloads are not emitted.',
            'Actual byte equality, noncontiguous sender validation and ACK acceptance remain assertions from the native test.',
            'Expected ready/consumed ACK bytes are derived but cannot be compared to unexported ACK captures.',
            'Loopback ring transport only; no model forwarding, physical link/RDMA or throughput qualification.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--epoch', required=True)
    parser.add_argument('rank0_stdout', type=Path)
    parser.add_argument('rank1_stdout', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = check_pair([args.rank0_stdout, args.rank1_stdout], args.epoch)
    result['auditHelperSHA256'] = digest(Path(__file__).read_bytes())
    data = json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + '\n'
    if args.output:
        with args.output.open('x') as stream:
            stream.write(data)
    print(data, end='')


if __name__ == '__main__':
    main()
