#!/usr/bin/env python3
"""Private guarded one-stage loading probe; no forward or throughput qualification."""
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
from stage_load_contract import (PROFILES, MINIMUM_FREE, MAX_STDOUT, MAX_STDERR,
    NATIVE_SECONDS, PARENT_SECONDS, require, bounded_regular, input_pins,
    power_policy, resource_policy, native_command, validate_result)

HERE = Path(__file__).resolve().parent
HELPERS = {
    'tiny_support.py': '5af27994877cfae28ed18861382681e2247920e6a78004c1e9ee7324c853e607',
    'prefill_compute_archive.py': 'dde031892fcec8c98b70f4b300e1ef1aaca309547c400b1a50d85e791e069930',
    'owned_bundle_reference.py': 'c4832e457307f683f5aff55cafefe6feeeaf6a69ad1be2dc220325f96f5da8a4',
}


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024**2), b''):
            value.update(block)
    return value.hexdigest()


def import_pinned(name):
    path = HERE / name
    require(sha(path) == HELPERS[name], 'Pinned private helper changed: ' + name)
    spec = importlib.util.spec_from_file_location('_stage_parent_' + path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_args(arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--release', required=True, type=Path)
    parser.add_argument('--model-dir', required=True, type=Path)
    parser.add_argument('--profile', required=True, choices=PROFILES)
    parser.add_argument('--stage-index', required=True, choices=('0', '1'))
    parser.add_argument('--expected-native-sha256', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--reuse-bundle', type=Path)
    parser.add_argument('--expected-bundle-manifest-sha256')
    args = parser.parse_args(arguments)
    require((args.reuse_bundle is None) == (args.expected_bundle_manifest_sha256 is None),
            'Bundle reuse requires both path and expected manifest pin')
    for value in [args.expected_native_sha256] + ([args.expected_bundle_manifest_sha256] if args.reuse_bundle else []):
        require(re.fullmatch('[0-9a-f]{64}', value), 'Invalid explicit SHA-256 pin')
    for value in (args.runtime, args.release, args.model_dir, args.output):
        require(value.is_absolute(), 'Explicit runtime, release, model and output paths must be absolute')
    args.stage_index = int(args.stage_index)
    return args


def observe(tiny, receipt, profile, process=None, executable=None):
    sample = tiny.sample(process.pid if process else None)
    receipt['memorySamples'].append(sample)
    # Retain raw observations even when the following policy refuses them.
    raw = tiny.read_command(['/usr/bin/pmset', '-g', 'batt'])
    power = dict(timestampUTC=datetime.now(timezone.utc).isoformat(), raw=raw)
    receipt['powerObservations'].append(power)
    power['admission'] = power_policy(raw)
    resource_policy(sample, profile, process.pid if process else None, executable)
    return sample


def output_bounds(out):
    require((out / 'stdout.jsonl').stat().st_size <= MAX_STDOUT and
            (out / 'stderr.log').stat().st_size <= MAX_STDERR, 'Selected-stage output exceeded its byte bound')


def supervise(process, out, tiny, receipt, profile, save, clock=time.monotonic, deadline=None):
    if deadline is None:
        deadline = clock() + PARENT_SECONDS
    executable = out / 'bundle/cluster-inference'
    while process.poll() is None:
        observe(tiny, receipt, profile, process, executable)
        require(clock() < deadline, 'Parent selected-stage deadline exceeded after observation')
        output_bounds(out)
        save()
        try:
            process.wait(timeout=0.25)
        except subprocess.TimeoutExpired:
            pass
    receipt.update(nativeExitCode=process.wait(), nativeReaped=True)
    require(clock() < deadline, 'Parent selected-stage deadline exceeded at completion')
    require(receipt['nativeExitCode'] == 0, 'Native selected-stage load failed')
    output_bounds(out)
    require((out / 'stderr.log').stat().st_size == 0, 'Selected-stage load emitted stderr')
    result = validate_result(bounded_regular(out / 'stdout.jsonl', MAX_STDOUT),
                             receipt['registeredProfile'], receipt['stageIndex'])
    require(clock() < deadline, 'Parent selected-stage deadline exceeded after output validation')
    receipt.update(result)


def run(args):
    runtime, release, directory = (value.resolve(strict=True) for value in (args.runtime, args.release, args.model_dir))
    repo = runtime.parents[2]
    require(runtime == repo / 'experiments/cluster/runtime' and release.is_dir() and directory.is_dir(),
            'Explicit source/runtime, release or model directory differs')
    require(not os.path.lexists(args.output), 'Output path already exists')
    out = args.output.resolve()
    require(out.parent.is_dir() and all(not out.is_relative_to(p) for p in (repo, directory, release)),
            'Output must be new and outside repository, release and model')
    tiny = import_pinned('tiny_support.py')
    archive = import_pinned('prefill_compute_archive.py')
    reuse = import_pinned('owned_bundle_reference.py') if args.reuse_bundle is not None else None
    out.mkdir(mode=0o700)
    profile = PROFILES[args.profile]
    sources = [Path(__file__).resolve(), HERE / 'stage_load_contract.py'] + [HERE / name for name in HELPERS]
    source_pins = {p.name: sha(p) for p in sources}
    receipt = dict(kind='private_guarded_registered_selected_stage_load', schemaVersion=1,
        startedAtUTC=datetime.now(timezone.utc).isoformat(), status='preparing',
        registeredProfile=args.profile, stageIndex=args.stage_index, expectedIdentity=profile,
        runtime=str(runtime), release=str(release), modelDirectory=str(directory),
        expectedNativeSHA256=args.expected_native_sha256, privateSourceSHA256=source_pins,
        nativeExecutionAttempted=False, nativeExecutions=0, nativePID=None,
        nativeReaped=False, nativeExitCode=None, primaryFailure=None,
        cleanupErrors=[], postRunErrors=[], memorySamples=[], powerObservations=[],
        nativeTimeoutSeconds=NATIVE_SECONDS, parentExecutionTimeoutSeconds=PARENT_SECONDS,
        initialActualFreeGateBytes=MINIMUM_FREE, everySavedSampleActualFreeGateBytes=MINIMUM_FREE,
        maximumSampledNativeRSSBytes=profile['maximumSampledRSSBytes'],
        memoryPolicy='actual free >=6GiB; pressure 0...2; absolute reported swap zero; fixed per-profile sampled RSS cap',
        powerPolicy='AC or observed internal battery >=15 percent, checked with every saved memory sample',
        sampledRSSIsNotPeakGuarantee=True, missingRSSIsNotZero=True,
        nativeResourcePolicyChanged=False, parentScreenGrantsNativeAllocationPermission=False,
        independentMetadataAuditPerformed=False, independentTensorAuditPerformed=False,
        selectedStageWeightMaterializationRequested=True, modelForwardAuthorized=False,
        physicalTwoMachineExecution=False, throughputQualification=False)
    save = lambda: archive.write_json(out / 'receipt.json', receipt)
    save()
    process = modules = source_manifest = bundle_sha = raw_pins = bundle_reference = None
    try:
        for source in sources:
            shutil.copyfile(source, out / source.name)
            (out / source.name).chmod(0o400)
        raw_pins = input_pins(directory, profile)
        receipt['rawMetadataPins'] = raw_pins
        require(sha(release / 'cluster-inference') == args.expected_native_sha256, 'Native pin differs')
        observe(tiny, receipt, profile)
        live = tiny.read_command(['/bin/ps', '-axo', 'command='])
        require(not any('/cluster-inference ' in line or '/rank_worker.py ' in line for line in live.splitlines()),
                'Another native inference experiment is active')
        source_manifest = archive.archive_sources(runtime, out)
        modules = archive.load_archived_runtime(out, uuid.uuid4().hex)
        if reuse:
            bundle_reference = reuse.create_reference(args.reuse_bundle, out / 'bundle',
                args.expected_bundle_manifest_sha256, args.expected_native_sha256,
                out / 'source/experiments/cluster/runtime', modules['artifacts'])
            bundle_sha = bundle_reference['manifestSHA256']
            receipt.update(bundleAcquisition='reused_external_reference', bundleReference=bundle_reference,
                           bundleCopiedForThisRun=False, bundleReferenceHelperSHA256=HELPERS['owned_bundle_reference.py'])
        else:
            bundle_sha = modules['bundle'].snapshot(release, out / 'bundle')
            receipt.update(bundleAcquisition='fresh_snapshot', bundleCopiedForThisRun=True)
        require(sha(out / 'bundle/cluster-inference') == args.expected_native_sha256, 'Archived native differs')
        receipt.update(sourceManifestSHA256=sha(out / 'source-manifest.json'),
            sourceFileCount=len(source_manifest['files']), bundleManifestSHA256=bundle_sha)
        archive.verify_archive(modules, out, source_manifest, bundle_sha, [])
        if bundle_reference is not None:
            reuse.check_reference(out / 'bundle', bundle_reference,
                out / 'source/experiments/cluster/runtime', modules['artifacts'])
        require(input_pins(directory, profile) == raw_pins, 'Input metadata changed before launch')
        observe(tiny, receipt, profile)
        command = native_command(out / 'bundle/cluster-inference', directory, args.profile, args.stage_index)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(('MLX_', 'DARKBLOOM_', 'JACCL_'))}
        environment.update(tiny.ENVIRONMENT)
        receipt.update(command=command, arithmeticEnvironment=tiny.ENVIRONMENT,
                       nativeExecutionAttempted=True, status='running')
        save()
        with (out / 'stdout.jsonl').open('xb') as stdout, (out / 'stderr.log').open('xb') as stderr:
            os.fchmod(stdout.fileno(), 0o600); os.fchmod(stderr.fileno(), 0o600)
            deadline = time.monotonic() + PARENT_SECONDS
            process = subprocess.Popen(command, cwd=out / 'bundle', env=environment,
                stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
            receipt.update(nativePID=process.pid, nativeExecutions=1)
            save()
            supervise(process, out, tiny, receipt, profile, save, deadline=deadline)
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
        def post(name, body):
            try:
                body()
            except BaseException as error:
                receipt['postRunErrors'].append(dict(action=name, error=type(error).__name__ + ': ' + str(error)))
        post('released_resources_and_power', lambda: observe(tiny, receipt, profile))
        if raw_pins is not None:
            post('raw_metadata_recheck', lambda: require(input_pins(directory, profile) == raw_pins, 'Input metadata changed'))
        if modules and source_manifest and bundle_sha:
            post('source_archive_bundle_recheck', lambda: archive.verify_archive(modules, out, source_manifest, bundle_sha, []))
        if bundle_reference is not None:
            post('reused_bundle_reference_recheck', lambda: reuse.check_reference(out / 'bundle', bundle_reference,
                out / 'source/experiments/cluster/runtime', modules['artifacts']))
        def private_sources():
            for source in sources:
                require(sha(source) == source_pins[source.name] and sha(out / source.name) == source_pins[source.name],
                        'Private source or archived copy changed: ' + source.name)
            require(sha(release / 'cluster-inference') == args.expected_native_sha256, 'Original release native changed')
        post('private_sources_and_release_recheck', private_sources)
        for name, limit in [('stdout.jsonl', MAX_STDOUT), ('stderr.log', MAX_STDERR)]:
            def stream_pin(name=name, limit=limit):
                path = out / name
                if path.exists():
                    size = path.stat().st_size
                    digest = None
                    if size <= limit:
                        data = bounded_regular(path, limit)
                        size, digest = len(data), hashlib.sha256(data).hexdigest()
                    receipt[name] = dict(sizeBytes=size, sha256=digest, hashOmittedBecauseOversized=size > limit)
            post('retained_stream_pin_' + name, stream_pin)
        passed = (receipt['nativeReaped'] and receipt['nativeExitCode'] == 0 and
                  receipt.get('outerIdentityAndScopeValidated') is True and not receipt['primaryFailure'] and
                  not receipt['cleanupErrors'] and not receipt['postRunErrors'])
        receipt.update(finishedAtUTC=datetime.now(timezone.utc).isoformat(), status='completed' if passed else 'failed')
        save()
    return receipt


def main(arguments=None):
    args = parse_args(arguments)
    receipt = run(args)
    print(json.dumps(dict(status=receipt['status'], receipt=str(args.output / 'receipt.json'),
        sha256=sha(args.output / 'receipt.json'), primaryFailure=receipt['primaryFailure'],
        cleanupErrors=receipt['cleanupErrors'], postRunErrors=receipt['postRunErrors'])))
    return 0 if receipt['status'] == 'completed' else 1


def interrupted(signum, _frame):
    raise KeyboardInterrupt('Selected-stage parent interrupted by signal ' + str(signum))


if __name__ == '__main__':
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
