#!/usr/bin/env python3
"""Small source-preservation check; no native, model or network work."""
from pathlib import Path
import hashlib
import json
import subprocess

HERE = Path(__file__).resolve().parent
PROPOSED = HERE / 'proposed'
ORIGINAL = HERE / 'originals'

def check_transform(name, changes):
    old = (ORIGINAL / name).read_text()
    expected = old
    for before, after in changes:
        assert expected.count(before) == 1, (name, before)
        expected = expected.replace(before, after)
    assert (PROPOSED / name).read_text() == expected, name

def main():
    for record in json.loads((HERE / 'origin-pins.json').read_text()):
        assert hashlib.sha256((ORIGINAL / record['path']).read_bytes()).hexdigest() == record['sha256']
    for record in json.loads((HERE / 'runtime-pins.json').read_text()):
        assert hashlib.sha256((PROPOSED / record['path']).read_bytes()).hexdigest() == record['sha256']
    check_transform('libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentRuntime+Load.swift', [
        ('public static func load(_ configuration: QwenResidentLoadConfiguration) throws -> QwenResidentRuntime {',
         'public static func load(_ configuration: QwenResidentLoadConfiguration,\n'
         '                            bootstrap: QwenResidentBootstrap? = nil) throws -> QwenResidentRuntime {\n'
         '        // nil preserves the legacy experimental native TCP bootstrap.\n'
         '        let nativeBootstrap = try bootstrap?.make(configuration: configuration)'),
        ('let collective = try Collective(transport: .jaccl)',
         'let collective = try Collective(transport: .jaccl, bootstrap: nativeBootstrap)'),
    ])
    check_transform('libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/WorkerMain.swift', [
        ('NativeWorkerRuntime(configuration.load)', 'NativeWorkerRuntime(configuration.load, bootstrap: configuration.bootstrap)'),
    ])
    check_transform('libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/NativeWorkerRuntime.swift', [
        ('    init(_ configuration: QwenResidentLoadConfiguration) throws { owner = try .load(configuration) }',
         '    init(_ configuration: QwenResidentLoadConfiguration, bootstrap: WorkerBootstrapConfiguration? = nil) throws {\n'
         '        let attachment = try bootstrap?.connect(epoch: configuration.identity.membershipEpoch, rank: configuration.rank)\n'
         '        owner = try .load(configuration, bootstrap: attachment.map { QwenResidentBootstrap(connection: $0) })\n'
         '    }'),
    ])
    for record in json.loads((HERE / 'Tests/protocol-pins.json').read_text()):
        local = HERE / 'Tests/protocol' / Path(record['path']).name
        assert hashlib.sha256(local.read_bytes()).hexdigest() == record['sha256']
    for source in sorted(PROPOSED.rglob('*.swift')):
        if source.name != 'Package.swift':
            subprocess.run(['swiftc', '-frontend', '-parse', str(source)], check=True, capture_output=True)
    print('PASS captured origins, 12 runtime pins, three exact preserved bodies, six unchanged protocol inputs, Swift syntax')

if __name__ == '__main__':
    main()
