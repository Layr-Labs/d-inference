"""Root-reviewed CPU-only microbenchmark. Run only after explicit slot grant."""
import argparse
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

from owned_process import invoke_controller

BASE = Path(__file__).resolve().parent
SHAPES = {'9b_prefill_bf16_c512': 4_194_304, '27b_prefill_bf16_c512': 5_242_880,
          '9b_decode_bf16': 8_192, '27b_decode_bf16': 10_240}


def verify_snapshot():
    snapshot = json.loads((BASE / 'compilation-snapshot.json').read_text())
    for item in snapshot['files']:
        raw = (BASE / item['path']).read_bytes()
        if len(raw) != item['sizeBytes'] or hashlib.sha256(raw).hexdigest() != item['sha256']:
            raise ValueError('Frozen benchmark input changed: ' + item['path'])
    return snapshot


def run_owned(argv, output, name, timeout):
    start = time.monotonic()
    record = {'argv': argv, 'timeoutSeconds': timeout, 'timedOut': False}
    try:
        with (output / (name + '.stdout')).open('xb') as stdout, (output / (name + '.stderr')).open('xb') as stderr:
            with contextlib.redirect_stdout(io.StringIO()) as observation:
                invoke_controller(argv, stdout, stderr, record, timeout=timeout)
            record['launchObservation'] = observation.getvalue()
    except BaseException as error:
        record['timedOut'] = isinstance(error, subprocess.TimeoutExpired)
        raise
    finally:
        record['elapsedSeconds'] = time.monotonic() - start
        (output / (name + '.json')).write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    for suffix in ['stdout', 'stderr']:
        if (output / (name + '.' + suffix)).stat().st_size > 1_048_576:
            raise ValueError('Retained diagnostic output exceeds limit')
    if record.get('exitCode') != 0 or record['timedOut'] or not record.get('reaped') or not record.get('groupAbsent'):
        raise ValueError(name + ' failed; raw evidence retained')
    if (output / (name + '.stderr')).stat().st_size:
        raise ValueError(name + ' stderr is not empty')
    return record


def validate_result(value):
    if value.get('schema') != 'darkbloom_authenticated_record_cpu_benchmark_v1':
        raise ValueError('Wrong CPU benchmark schema')
    if any(value.get(name) is not False for name in ['encryptedRDMAMeasured', 'modelMeasured', 'keysLogged']):
        raise ValueError('Unexpected scope claim')
    if value.get('hostChip') != 'Apple M4 Max': raise ValueError('Wrong observed CPU identity')
    cases = value.get('cases')
    if not isinstance(cases, list) or len(cases) != 8: raise ValueError('Missing CPU cases')
    expected = {(name, rank) for name in SHAPES for rank in [0, 1]}
    seen = set(); summaries = []
    for case in cases:
        if type(case.get('sourceRank')) is not int: raise ValueError('Invalid rank type')
        key = (case.get('name'), case.get('sourceRank'))
        if key not in expected or key in seen: raise ValueError('Wrong/duplicate case')
        seen.add(key); size = SHAPES[key[0]]
        required = {'destinationRank': 1 - key[1], 'plaintextBytes': size, 'sealedBytes': size + 40,
            'warmupCount': 3, 'measuredCount': 20, 'verifiedPlaintextCount': 23,
            'sequenceStartsAt': 0, 'sequenceEndsAt': 22, 'sealedRecords': 23, 'openedRecords': 23,
            'sealedPlaintextBytes': size * 23, 'openedPlaintextBytes': size * 23}
        for field, wanted in required.items():
            if type(case.get(field)) is not int or case[field] != wanted: raise ValueError('Counter/geometry differs: ' + field)
        if case.get('freshSessionKeyGenerated') is not True or case.get('codecsInvalidatedAfterMeasurements') is not True:
            raise ValueError('Fresh-key/invalidation case incomplete')
        warmup, measured = case.get('warmup'), case.get('samples')
        if not isinstance(warmup, list) or not isinstance(measured, list) or len(warmup) != 3 or len(measured) != 20:
            raise ValueError('Missing warmup/measured samples')
        for ordinal, sample in enumerate(warmup + measured):
            for field, wanted in [('ordinal', ordinal), ('plaintextBytes', size), ('sealedBytes', size + 40)]:
                if type(sample.get(field)) is not int or sample[field] != wanted: raise ValueError('Sample identity differs')
            for field in ['sealNanoseconds', 'openNanoseconds', 'pairedNanoseconds', 'betweenCallsNanoseconds']:
                if type(sample.get(field)) is not int or sample[field] < 0: raise ValueError('Invalid clock delta')
            if sample['sealNanoseconds'] == 0 or sample['openNanoseconds'] == 0:
                raise ValueError('Zero operation delta')
            if sample['pairedNanoseconds'] != sample['sealNanoseconds'] + sample['openNanoseconds'] + sample['betweenCallsNanoseconds']:
                raise ValueError('Paired clock interval differs')
        summary = {'name': key[0], 'sourceRank': key[1], 'plaintextBytes': size, 'sealedBytes': size + 40}
        for phase in ['seal', 'open', 'paired']:
            values = [row[phase + 'Nanoseconds'] for row in measured]
            median = statistics.median(values)
            summary[phase] = {'medianNanoseconds': median, 'minimumNanoseconds': min(values),
                'maximumNanoseconds': max(values), 'plaintextMiBPerSecondAtMedian': size * 1e9 / median / (1024 * 1024)}
        summaries.append(summary)
    if seen != expected: raise ValueError('Case coverage differs')
    return summaries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(mode=0o700, parents=False, exist_ok=False)
    snapshot = verify_snapshot(); os.chdir(BASE)
    (output / 'module-cache').mkdir(mode=0o700)
    binary = output / 'authenticated-record-benchmark'
    sources = [str(BASE / name) for name in snapshot['swiftSources']]
    command = ['xcrun', 'swiftc', '-j', '2', '-O', '-swift-version', '6', '-warnings-as-errors',
               '-target', platform.machine() + '-apple-macos14.0', '-parse-as-library',
               '-module-cache-path', str(output / 'module-cache')] + sources + ['-o', str(binary)]
    compile_receipt = run_owned(command, output, 'compile', 60); verify_snapshot()
    benchmark_receipt = run_owned([str(binary)], output, 'benchmark', 30); verify_snapshot()
    raw = json.loads((output / 'benchmark.stdout').read_text())
    summaries = validate_result(raw)
    result = {'passed': True, 'scope': 'same-CPU CryptoKit codec microbenchmark only',
        'codecSourceManifestSHA256': 'c206c9e0860c641de64057a48652887ed93a4737edf0a4db16a4ba4251f692ac',
        'compile': compile_receipt, 'benchmark': benchmark_receipt, 'sourceUnchanged': True,
        'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'hostChip': raw['hostChip'], 'hostArchitecture': platform.machine(), 'macOSVersion': platform.mac_ver()[0],
        'encryptedRDMAMeasured': False, 'modelMeasured': False,
        'summary': summaries,
        'rateDefinition': 'one plaintext payload per operation or sequential seal+open pair; paired does not double-count bytes'}
    (output / 'result.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'passed': True, 'cases': 8, 'measuredSamples': 160, 'warmupSamples': 24,
                      'encryptedRDMAMeasured': False}))


if __name__ == '__main__': main()
