from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent
original = (ROOT / 'originals/CBv2RequestSession.swift').read_text()
changed = (ROOT / 'Sources/CBv2RequestSession.swift').read_text()
start = changed.index('    /// Explicit clean generation completion, including early EOS. The existing\n')
end = changed.index('    /// Cleanup is idempotent and retires the entire request even when a forward\n', start)
restored = changed[:start] + changed[end:]
restored = restored.replace('    private var generationCompleted = false\n', '', 1)
restored = restored.replace('guard isFailed || generationCompleted || (promptFinished',
                            'guard isFailed || (promptFinished', 1)
assert restored == original, 'existing init/forward/state/snapshot/retirement body changed'
listing = json.loads((ROOT / 'foundation-source-list.json').read_text())
for entry in listing['sources'] + [listing['stdin']]:
    assert hashlib.sha256(Path(entry['path']).read_bytes()).hexdigest() == entry['sha256'], entry['path']
for entry in json.loads((ROOT / 'integration.json').read_text()):
    path = ROOT / entry['source']
    assert hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256'], str(path)
print(json.dumps({'sourceChecksPassed': True, 'existingCBv2MathBytesUnchanged': True,
                  'foundationSources': len(listing['sources']), 'nativeExecution': False}, sort_keys=True))
