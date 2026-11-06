from pathlib import Path
import hashlib
import json

draft = Path(__file__).resolve().parent
repo = Path('/Users/developer/DarkbloomDev/d-inference')
runtime = Path('libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')
proposed = draft / 'proposed' / runtime
original = draft / 'originals'
checks = []

def check(value, name):
    if not value:
        raise AssertionError(name)
    checks.append(name)

def body(text, marker):
    start = text.index('{', text.index(marker))
    depth = 0
    for end in range(start, len(text)):
        if text[end] == '{': depth += 1
        elif text[end] == '}': depth -= 1
        if depth == 0: return text[start:end + 1]
    raise AssertionError('unclosed source body')

for row in json.loads((draft/'base-pins.json').read_text())['files']:
    check(hashlib.sha256((repo/row['path']).read_bytes()).hexdigest() == row['sha256'], 'main base unchanged: '+row['path'])
    check(hashlib.sha256((original/Path(row['path']).name).read_bytes()).hexdigest() == row['sha256'], 'saved original: '+Path(row['path']).name)
old = (original/'QwenLayerStageGenerationDriver.swift').read_text()
new = (proposed/'QwenLayerStageGenerationDriver.swift').read_text()
for name in ['requireGenerationSource', 'runGenerationFrame', 'agreeGenerationToken']:
    check(body(old, 'func '+name+'(') == body(new, 'func '+name+'('), 'unchanged actual '+name)
start = '                        guard control.phase == .token else { return }'
end = '                guard control.phase == .retiring'
check(old[old.index(start):old.index(end)] == new[new.index(start):new.index(end)], 'token/decision/final-row body unchanged')
old = (original/'QwenLayerStageGenerationTransport.swift').read_text()
new = (proposed/'QwenLayerStageGenerationTransport.swift').read_text()
for name in ['receiveBoundary<T>', 'sendToken', 'receiveToken', 'acknowledgeToken', 'sendDecision',
             'receiveDecision', 'acknowledgeDecision', 'exchangeRetirement', 'sendData', 'receiveData',
             'sendAck', 'receiveAckValues', 'receiveAck']:
    check(body(old, 'func '+name+'(') == body(new, 'func '+name+'('), 'unchanged native '+name)
prefix = body(old, 'func sendBoundary(')
expected = prefix.replace('            try receiveAck(.boundaryConsumed, packet.fingerprint, from: 1, check: check)',
    '            pendingBoundaryFingerprint = packet.fingerprint\n            return BoundaryTicket(packet: packet)')
check(body(new, 'func sendBoundaryUntilSent(') == expected, 'send prefix/native operation order exact before consumed split')
support = (draft/'Tests/ExtractedCPUValues.swift').read_text()
check(body(support, 'struct QwenLayerStageSessionIdentity:') == body((repo/runtime/'QwenLayerStageSession.swift').read_text(),
    'struct QwenLayerStageSessionIdentity:'), 'exact CPU identity extraction')
check(body(support, 'func sha256(') == body((repo/runtime/'QwenModelConstruction.swift').read_text(), 'func sha256('),
    'exact SHA helper extraction')
result = {'scope':'static source comparison only; no native/MLX execution', 'passed':len(checks), 'checks':checks}
(draft/'source-checks.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps({'passed':len(checks)}))
