"""Assemble a Foundation/CryptoKit-only interpreter harness, without executing it."""
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference')
NAMES = ['QwenLayerStageSchedule.swift', 'WorkerJSONScanner.swift', 'BoundedProbeInput.swift',
    'CanonicalJSON.swift', 'QwenLayerStageWireExpectation.swift', 'QwenLayerStageBoundaryWireHeader.swift',
    'QwenLayerStageWireAcknowledgement.swift', 'QwenLayerStageBoundaryWireCheck.swift']
DRAFTS = ['QwenLayerStageLookaheadWireEnvelope.swift', 'QwenLayerStageLookaheadWireAcknowledgement.swift',
    'QwenLayerStageLookaheadWireCheck.swift']
SUPPORT = '''import Foundation
import CryptoKit

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func emitJSON<T: Encodable>(_ value: T) throws {
    let bytes = try canonicalJSONData(value)
    FileHandle.standardOutput.write(bytes + Data([10]))
}
'''


def sha(data): return hashlib.sha256(data).hexdigest()


def main():
    parts, entries = [SUPPORT], []
    for path in [SOURCE / name for name in NAMES] + [HERE / name for name in DRAFTS]:
        data = path.read_bytes()
        assert b'import MLX' not in data and b'import Cmlx' not in data
        parts.append('\n// Verbatim input: ' + str(path) + '\n' + data.decode())
        entries.append(dict(path=str(path), sizeBytes=len(data), sha256=sha(data)))
    parts.append('\ntry checkQwenLayerStageBoundaryWire()\ntry checkQwenLayerStageLookaheadWire(includeVectors: true)\n')
    target = HERE / 'lookahead-foundation-check.swift'; data = '\n'.join(parts).encode()
    assert not target.exists(), 'Preserve existing generated harness'
    target.write_bytes(data)
    manifest = dict(schemaVersion=1, generatorSHA256=sha(Path(__file__).read_bytes()),
        harnessPath=str(target), harnessSHA256=sha(data), supportSHA256=sha(SUPPORT.encode()),
        sourceInputs=entries, sourceConcatenationOnly=True, inferenceBuild=False, MLXImports=False)
    with (HERE / 'foundation-harness-inputs.json').open('x') as stream:
        json.dump(manifest, stream, indent=2, sort_keys=True); stream.write('\n')
    print(json.dumps(dict(harness=str(target), sha256=sha(data), inputFiles=len(entries)), sort_keys=True))


if __name__ == '__main__': main()
