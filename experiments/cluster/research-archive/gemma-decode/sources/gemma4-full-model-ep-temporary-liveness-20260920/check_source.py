"""Small source pins/inverses only; no fixture, compiler or model execution."""
import ast
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def section(text, start, end):
    assert text.count(start) == 1 and text.count(end) == 1
    return text.split(start, 1)[1].split(end, 1)[0]


def main():
    assert sys.argv[1:] in ([], ['--frozen-only'])
    frozen_only = bool(sys.argv[1:])
    data = json.loads((ROOT / 'overlay.json').read_text())
    preimages = json.loads((ROOT / 'preimages.json').read_text())
    assert sha(Path(data['appliedSourceReceipt'])) == data['appliedSourceReceiptSHA256']
    for name, pin in preimages.items():
        assert sha(ROOT / 'originals' / name) == pin['sha256']
        assert sha(Path(pin['path'])) == pin['sha256']
    for row in data['overlays']:
        assert sha(ROOT / row['candidate']) == row['sha256']
        if not frozen_only:
            target = Path(data['baseWorkspace']) / row['destination']
            assert sha(target) == row['beforeSHA256'] if row['beforeSHA256'] else not target.exists()
    for row in data['proofDependencies']:
        assert sha(Path(row['path'])) == row['sha256']
    for row in data['auxiliaryFiles']:
        assert sha(ROOT / row['path']) == row['sha256']
    for path in ROOT.rglob('*.py'):
        ast.parse(path.read_text(), filename=str(path))

    before = (ROOT / 'originals/Gemma4ShortResourceOwner.swift').read_text()
    after = (ROOT / 'Runtime/Gemma4ShortResourceOwner.swift').read_text()
    assert section(before, '    func check() throws {', '    func construction(') == section(
        after, '    func check() throws {', '    func construction(')
    before = (ROOT / 'originals/Gemma4ShortResourceBudget.swift').read_text()
    after = (ROOT / 'Runtime/Gemma4ShortResourceBudget.swift').read_text()
    assert section(before, '        let selected =', '        let expertResources:') == section(
        after, '        let selected =', '        let expertResources:')

    before = (ROOT / 'originals/Gemma4ExpertCollectiveOperation.swift').read_text()
    after = (ROOT / 'Runtime/Gemma4ExpertCollectiveOperation.swift').read_text()
    anchor = '        try check()\n        guard (0..<30)'
    before = before[before.index(anchor):]
    after = after[after.index(anchor):]
    start = after.index('        if let temporaryPolicy {')
    end = after.index('        // The existing owner', start)
    after = after[:start] + after[end:]
    after = after.replace('        try temporaryWindow?.inputEvaluated()\n', '')
    after = after.replace('''        // The concrete Wire returned only after existing CPU/GPU completion
        // fences and consumed ACKs. No extra synchronization is introduced.
        try temporaryWindow?.exchangeCompleted()
''', '')
    after = after.replace('''        let result = joined.take(order, axis: 0).reshaped(input.dim(0), 8, 2816)
        try temporaryWindow?.returned()
        return result''', '''        return joined.take(order, axis: 0).reshaped(input.dim(0), 8, 2816)''')
    assert before == after, 'Numerical/check/transfer hook body changed outside the scalar guard'
    print(json.dumps(dict(sourceOnly=True, runtimeOverlays=len(data['overlays']),
        proofSources=len(data['proofDependencies']), ownerCheckInverse=True,
        fullTrunkBudgetInverse=True, hookBodyInverse=True,
        fixturesExecuted=False, compilerExecuted=False, nativeExecuted=False)))


if __name__ == '__main__':
    main()
