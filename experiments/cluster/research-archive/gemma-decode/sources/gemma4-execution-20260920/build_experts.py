"""Compose reviewed additions in the disposable workspace; build serially."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent
WORK = ROOT / 'build/workspace'
PRIMITIVE = ROOT.parent / 'gemma4-expert-native-20260920'
RDMA = ROOT.parent / 'gemma4-expert-rdma-20260920'
LIFETIME = ROOT.parent / 'gemma4-expert-rdma-send-lifetime-20260920'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(path, row):
    assert path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], path


def apply():
    for source, wanted in [(RDMA, '96f99cd4486a49decd786b59a600e7e729f171a62805a4fff9ad5f97157a7f1f'),
                           (LIFETIME, '38b5605f6df58da929d3b8c5c0a4ea26a69d759af6089f2cce9a4e0fdeee50f6')]:
        assert digest(source / 'manifest.json') == wanted
        for row in json.loads((source / 'manifest.json').read_bytes())['files']:
            verify(source / row['path'], row)
    baseline = json.loads((ROOT / 'build/applied-benchmark.json').read_bytes())
    for row in baseline['files']:
        verify(WORK / row['path'], row)
    integration = json.loads((RDMA / 'integration.json').read_bytes())
    rows = []
    for row in integration['requiresWholeExpertRuntime']:
        source = Path(row['path']); verify(source, row)
        rows.append((source, WORK / 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime' / source.name))
    rows.append((PRIMITIVE / 'Entry/main.swift', WORK / 'libs/darkbloom-cluster-worker/Tests/GemmaExpertAxisCheck/main.swift'))
    package = WORK / 'libs/darkbloom-cluster-worker/Package.swift'
    for row in integration['entries']:
        source = RDMA / row['source']; verify(source, row['after'])
        if row['destination'].endswith('/Package.swift'):
            verify(package, row['before'])
        else:
            assert row['before'] is None
            rows.append((source, WORK / row['destination']))
    for source, destination in rows:
        assert not destination.exists(), destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('xb') as stream:
            stream.write(source.read_bytes())
    wire = WORK / 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/ExpertAxisRDMAWire.swift'
    fix = json.loads((LIFETIME / 'integration.json').read_bytes())
    verify(wire, fix['before'])
    wire.write_bytes((LIFETIME / 'Runtime/ExpertAxisRDMAWire.swift').read_bytes())
    verify(wire, fix['after'])
    before = package.read_text()
    (ROOT / 'build/expert-Package.before.swift').write_text(before)
    products = ['GemmaExpertAxisCheck', 'GemmaExpertRDMACheck']
    after = before.replace('    products: [\n', '    products: [\n' + ''.join(
        f'        .executable(name: "{name}", targets: ["{name}"]),\n' for name in products), 1)
    after = after.replace('    targets: [\n', '    targets: [\n' + ''.join(
        f'        .executableTarget(name: "{name}", dependencies: [\n'
        '            .product(name: "DarkbloomClusterRuntime", package: "darkbloom-cluster"),\n'
        f'        ], path: "Tests/{name}"),\n' for name in products), 1)
    package.write_text(after)
    (ROOT / 'build/expert-Package.after.swift').write_text(after)
    paths = sorted({destination for _, destination in rows} | {package} |
                   {WORK / row['path'] for row in baseline['files']})
    receipt = {'files': [dict(path=str(path.relative_to(WORK)), bytes=path.stat().st_size,
                              sha256=digest(path)) for path in paths]}
    with (ROOT / 'build/applied-experts.json').open('x') as stream:
        json.dump(receipt, stream, indent=2)
    return receipt


def build(product, sources, attempt=1, source_receipt='applied-experts.json'):
    package = WORK / 'libs/darkbloom-cluster-worker'
    command = ['/usr/bin/swift', 'build', '--package-path', str(package), '--scratch-path',
               str(package / '.build-native-worker'), '-c', 'release', '--jobs', '2',
               '--disable-automatic-resolution', '--skip-update', '--disable-build-manifest-caching',
               '--triple', 'arm64-apple-macosx26.2', '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2',
               '--product', product]
    log = ROOT / 'build' / (product + f'-build-{attempt}.log')
    started = time.monotonic()
    with log.open('xb') as stream:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=600)
        except BaseException:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)
            raise
    for row in sources['files']:
        verify(WORK / row['path'], row)
    binary = package / '.build-native-worker/arm64-apple-macosx/release' / product
    receipt = dict(product=product, exitCode=code, elapsedSeconds=time.monotonic()-started,
                   logSHA256=digest(log), sourcesSHA256=digest(ROOT / 'build' / source_receipt),
                   compilerReaped=True, gpuExecuted=False)
    if code == 0:
        receipt.update(nativeSHA256=digest(binary), nativeBytes=binary.stat().st_size,
                       target=subprocess.check_output(['/usr/bin/xcrun', 'vtool', '-show-build', str(binary)], text=True))
    with (ROOT / 'build' / (product + f'-build-{attempt}.json')).open('x') as stream:
        json.dump(receipt, stream, indent=2)
    print(json.dumps(receipt), flush=True)
    assert code == 0, log


if __name__ == '__main__':
    sources = apply()
    for product in ['GemmaExpertAxisCheck', 'GemmaExpertRDMACheck']:
        build(product, sources)
