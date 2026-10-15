#!/usr/bin/env python3
"""Root-owned exact-profile constructor probe; no weight-loading permission."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path('/Users/developer/DarkbloomDev')
REPO = ROOT / 'd-inference'
RESEARCH = ROOT / 'cluster-research'
TINY = RESEARCH / 'run-profiled-tiny-stage-check-20260914.py'
TINY_SHA = '5af27994877cfae28ed18861382681e2247920e6a78004c1e9ee7324c853e607'
ARCHIVE = RESEARCH / 'remote-solo-prefill-launcher-draft/prefill_compute_archive.py'
ARCHIVE_SHA = 'dde031892fcec8c98b70f4b300e1ef1aaca309547c400b1a50d85e791e069930'
PROFILES = {
    'registered_qwen35_9b': {
        'directory': 'Qwen3.5-9B',
        'configuration': 'c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423',
        'manifest': '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4',
        'artifact': '127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b',
        'canonicalTensorCount': 927,
    },
    'registered_qwen38_27b': {
        'directory': 'Qwen3.8-27B',
        'configuration': '4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff',
        'manifest': 'd1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc',
        'artifact': 'bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463',
        'canonicalTensorCount': 1847,
    },
}
MAX_STDOUT = 8 * 1024**2
MAX_STDERR = 65536
MAX_SAMPLED_RSS = 1024**3


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def import_pinned(path, expected, name):
    require(sha(path) == expected, 'Pinned private helper changed')
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def input_pins(directory, profile):
    result = {}
    for name, key, limit in [('config.json', 'configuration', 65536),
                             ('manifest.json', 'manifest', 4 * 1024**2)]:
        path = directory / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= limit,
                'Expected bounded regular metadata file is unavailable')
        with path.open('rb') as stream:
            raw = stream.read(limit + 1)
        require(len(raw) <= limit, 'Registered raw metadata exceeded its read bound')
        require(hashlib.sha256(raw).hexdigest() == profile[key], 'Registered raw metadata pin differs')
        result[name] = dict(sizeBytes=len(raw), sha256=profile[key])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', required=True, choices=PROFILES)
    parser.add_argument('--expected-native-sha256', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    require(re.fullmatch('[0-9a-f]{64}', args.expected_native_sha256), 'Invalid native pin')
    out = args.output.resolve()
    require(not out.exists() and out.parent.is_dir() and not out.is_relative_to(REPO),
            'Output must be new and outside the repository')
    profile = PROFILES[args.profile]
    directory = ROOT / 'models' / profile['directory']
    release = REPO / 'experiments/cluster/inference/.build/release'
    require(sha(release / 'cluster-inference') == args.expected_native_sha256, 'Native pin differs')
    tiny = import_pinned(TINY, TINY_SHA, '_dense_probe_tiny_support')
    archive = import_pinned(ARCHIVE, ARCHIVE_SHA, '_dense_probe_archive_support')
    out.mkdir(mode=0o700)
    driver_pin = sha(Path(__file__))
    receipt = dict(kind='root_guarded_dense_constructor_probe', schemaVersion=1,
        startedAtUTC=datetime.now(timezone.utc).isoformat(), status='preparing',
        registeredProfile=args.profile, expectedIdentity=profile,
        expectedNativeSHA256=args.expected_native_sha256, driverSHA256=driver_pin,
        tinySupportSHA256=TINY_SHA, archiveSupportSHA256=ARCHIVE_SHA,
        nativeExecutionAttempted=False, nativeExecutions=0, nativePID=None,
        nativeReaped=False, nativeExitCode=None, primaryFailure=None,
        cleanupErrors=[], postRunErrors=[], memorySamples=[],
        nativeTimeoutSeconds=120, parentExecutionTimeoutSeconds=135,
        initialActualFreeGateBytes=1024**3, maximumSampledNativeRSSBytes=MAX_SAMPLED_RSS,
        memoryPolicy='constructor graphs only; pressure<=2; no new reported swap; sampled RSS<=1GiB',
        sampledRSSIsNotPeakGuarantee=True, independentMetadataAuditPerformed=False,
        weightMaterializationAuthorized=False, modelForwardAuthorized=False,
        physicalTwoMachineExecution=False, throughputQualification=False)
    save = lambda: archive.write_json(out / 'receipt.json', receipt)
    save()
    process = None
    modules = source_manifest = bundle_sha = None
    initial = None
    raw_pins = None
    try:
        for source in [Path(__file__), TINY, ARCHIVE]:
            shutil.copyfile(source, out / source.name)
        raw_pins = input_pins(directory, profile)
        receipt['rawMetadataPins'] = raw_pins
        initial = tiny.sample()
        receipt['memorySamples'].append(initial)
        require(initial['actualFreeBytes'] >= 1024**3 and initial['pressureLevel'] <= 2,
                'Initial constructor resource screen refused')
        live = tiny.read_command(['/bin/ps', '-axo', 'command='])
        require(not any('/cluster-inference ' in line or '/rank_worker.py ' in line
                        for line in live.splitlines()), 'Another native inference experiment is active')
        power = tiny.read_command(['/usr/bin/pmset', '-g', 'batt'])
        receipt['initialPowerObservation'] = power
        require("Now drawing from 'AC Power'" in power, 'Local development Mac is not on AC')
        source_manifest = archive.archive_sources(REPO / 'experiments/cluster/runtime', out)
        modules = archive.load_archived_runtime(out, uuid.uuid4().hex)
        bundle_sha = modules['bundle'].snapshot(release, out / 'bundle')
        require(sha(out / 'bundle/cluster-inference') == args.expected_native_sha256,
                'Archived native differs')
        receipt.update(sourceManifestSHA256=sha(out / 'source-manifest.json'),
            sourceFileCount=len(source_manifest['files']), bundleManifestSHA256=bundle_sha)
        archive.verify_archive(modules, out, source_manifest, bundle_sha, [])
        before = tiny.sample()
        receipt['memorySamples'].append(before)
        tiny.require_resources(before, initial)
        require(before['actualFreeBytes'] >= 1024**3, 'Prelaunch constructor resource screen refused')
        require(input_pins(directory, profile) == raw_pins, 'Input metadata changed before launch')
        command = [str(out / 'bundle/cluster-inference'), '--mode', 'qwen-dense-constructor-check',
            '--model-dir', str(directory), '--registered-dense-profile', args.profile,
            '--timeout-seconds', '120']
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(('MLX_', 'DARKBLOOM_', 'JACCL_'))}
        environment.update(tiny.ENVIRONMENT)
        receipt.update(command=command, arithmeticEnvironment=tiny.ENVIRONMENT,
                       nativeExecutionAttempted=True, status='running')
        save()
        with (out / 'stdout.jsonl').open('xb') as stdout, (out / 'stderr.log').open('xb') as stderr:
            process = subprocess.Popen(command, cwd=out / 'bundle', env=environment,
                stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
            receipt.update(nativePID=process.pid, nativeExecutions=1)
            deadline = time.monotonic() + 135
            save()
            while process.poll() is None:
                observation = tiny.sample(process.pid)
                receipt['memorySamples'].append(observation)
                tiny.require_resources(observation, initial)
                require(time.monotonic() < deadline, 'Parent constructor deadline exceeded')
                rss = observation['nativeRSSBytes']
                require(rss is None or rss <= MAX_SAMPLED_RSS, 'Sampled native RSS exceeded constructor screen')
                require((out / 'stdout.jsonl').stat().st_size <= MAX_STDOUT and
                        (out / 'stderr.log').stat().st_size <= MAX_STDERR,
                        'Constructor output exceeded its byte bound')
                save()
                try:
                    process.wait(timeout=0.25)
                except subprocess.TimeoutExpired:
                    pass
            receipt.update(nativeExitCode=process.wait(), nativeReaped=True)
        require(time.monotonic() < deadline, 'Parent constructor deadline exceeded at completion')
        require(receipt['nativeExitCode'] == 0, 'Native constructor probe failed')
        require((out / 'stdout.jsonl').stat().st_size <= MAX_STDOUT and
                (out / 'stderr.log').stat().st_size <= MAX_STDERR,
                'Completed constructor output exceeded its byte bound')
        require((out / 'stderr.log').stat().st_size == 0, 'Constructor probe emitted stderr')
        lines = (out / 'stdout.jsonl').read_bytes().splitlines()
        require(len(lines) == 1, 'Constructor probe did not emit exactly one result')
        result = json.loads(lines[0])
        require(isinstance(result, dict) and result.get('kind') == 'qwen_dense_constructor_report',
                'Constructor probe emitted another result kind')
        receipt['resultRecordCount'] = 1
    except BaseException as error:
        receipt['primaryFailure'] = type(error).__name__ + ': ' + str(error)
    finally:
        if process is not None:
            try:
                receipt['cleanupErrors'].extend(tiny.stop_owned(process))
                receipt.update(nativeExitCode=process.poll(), nativeReaped=process.poll() is not None)
                receipt['ownedProcessGroupAfter'] = tiny.owned_group(process.pid)
                require(not receipt['ownedProcessGroupAfter'], 'Owned native process group remains')
            except BaseException as error:
                receipt['cleanupErrors'].append(type(error).__name__ + ': ' + str(error))
        try:
            after = tiny.sample()
            receipt['memorySamples'].append(after)
            if initial is not None:
                tiny.require_resources(after, initial)
            if raw_pins is not None:
                require(input_pins(directory, profile) == raw_pins, 'Input metadata changed')
            if modules and source_manifest and bundle_sha:
                archive.verify_archive(modules, out, source_manifest, bundle_sha, [])
            require(sha(Path(__file__)) == driver_pin and sha(TINY) == TINY_SHA and
                    sha(ARCHIVE) == ARCHIVE_SHA, 'Private driver/helper source changed')
        except BaseException as error:
            receipt['postRunErrors'].append(type(error).__name__ + ': ' + str(error))
        for name, limit in [('stdout.jsonl', MAX_STDOUT), ('stderr.log', MAX_STDERR)]:
            path = out / name
            if path.exists():
                size = path.stat().st_size
                receipt[name] = dict(sizeBytes=size, sha256=sha(path) if size <= limit else None,
                                     hashOmittedBecauseOversized=size > limit)
        passed = (receipt['nativeReaped'] and receipt['nativeExitCode'] == 0
                  and not receipt['primaryFailure'] and not receipt['cleanupErrors']
                  and not receipt['postRunErrors'])
        receipt.update(finishedAtUTC=datetime.now(timezone.utc).isoformat(),
                       status='completed' if passed else 'failed')
        save()
    print(json.dumps(dict(status=receipt['status'], receipt=str(out / 'receipt.json'),
        sha256=sha(out / 'receipt.json'), primaryFailure=receipt['primaryFailure'],
        cleanupErrors=receipt['cleanupErrors'], postRunErrors=receipt['postRunErrors'])))
    return 0 if receipt['status'] == 'completed' else 1


def interrupted(signum, _frame):
    raise KeyboardInterrupt('Root constructor probe interrupted by signal ' + str(signum))


if __name__ == '__main__':
    for signal_number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signal_number, interrupted)
    sys.exit(main())
