"""Qualify measured guard counters in the existing disposable native workspace."""
import json
import os
import signal
import subprocess
import time
from pathlib import Path

from build_experts import ROOT, WORK, build, digest, verify


def bounded(command, output, timeout=60):
    started = time.monotonic()
    with output.open('xb') as stream:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except BaseException:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=10)
            raise
    try:
        os.killpg(child.pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError('Compiler/control process group remains')
    receipt = dict(command=command, exitCode=code, elapsedSeconds=time.monotonic()-started,
                   reaped=True, groupAbsent=True, logSHA256=digest(output), gpuExecuted=False)
    with output.with_suffix('.json').open('x') as stream:
        json.dump(receipt, stream, indent=2)
    print(json.dumps(receipt), flush=True)
    assert code == 0, output


def main():
    draft = ROOT.parent / 'gemma4-benchmark-guard-metrics-20260920'
    manifest_path = draft / 'source-inputs.json'
    assert digest(manifest_path) == '84352102855784c7137546371eda5c77be427dee881a5f407d7b3c0cdf3d549c'
    manifest = json.loads(manifest_path.read_bytes())
    prior_path = ROOT / 'build/applied-lookahead-experts.json'
    assert digest(prior_path) == manifest['baseSourceReceipt']
    prior = json.loads(prior_path.read_bytes())
    for row in prior['files']:
        verify(WORK / row['path'], row)
    for row in manifest['additionalFiles']:
        verify(draft / row['path'], row)
    for row in manifest['entries']:
        destination = WORK / row['destination']
        if row['before'] is None:
            assert not destination.exists(), destination
        else:
            verify(destination, row['before'])
        verify(draft / row['source'], row['after'])
    binary = WORK / 'libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release/GemmaResidentBenchmark'
    assert digest(binary) == manifest['baseNative']
    preserve = ROOT / 'build/before-guard-metrics'
    preserve.mkdir(mode=0o700)
    subprocess.run(['/bin/cp', '-c', str(binary), str(preserve / binary.name)], check=True)
    assert digest(preserve / binary.name) == manifest['baseNative']
    for row in manifest['entries']:
        destination = WORK / row['destination']
        if destination.exists():
            backup = preserve / row['destination']
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_bytes(destination.read_bytes())
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((draft / row['source']).read_bytes())
        verify(destination, row['after'])
    paths = {WORK / row['path'] for row in prior['files']} | {
        WORK / row['destination'] for row in manifest['entries']}
    sources = dict(baseSourceReceipt=digest(prior_path), metricsSourceInputsSHA256=digest(manifest_path),
                   files=[dict(path=str(path.relative_to(WORK)), bytes=path.stat().st_size,
                               sha256=digest(path)) for path in sorted(paths)])
    name = 'applied-guard-metrics.json'
    with (ROOT / 'build' / name).open('x') as stream:
        json.dump(sources, stream, indent=2)
    controls = ROOT / 'metadata-checks/guard-metrics-v1'
    controls.mkdir(mode=0o700)
    runtime = WORK / 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    executable = controls / 'GuardMetricsChecks'
    bounded(['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-j', '2',
             str(runtime / 'Gemma4BenchmarkGuardMetrics.swift'),
             str(draft / 'Tests/GuardMetricsChecks.swift'), '-o', str(executable)], controls / 'compile.log')
    bounded([str(executable)], controls / 'controls.log')
    assert (controls / 'controls.log').read_text().count('PASS ') == 8
    build('GemmaResidentBenchmark', sources, attempt=4, source_receipt=name)


if __name__ == '__main__':
    main()
