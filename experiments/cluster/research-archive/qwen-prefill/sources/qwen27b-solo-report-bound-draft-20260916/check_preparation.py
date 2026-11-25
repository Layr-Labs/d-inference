"""Small source/metadata checks only; never materialize or scan model/build payloads."""
import ast
import hashlib
import json
from pathlib import Path
import sys
from build_inputs import BASE, OLD, authority
sys.path.insert(0,str(BASE/'Tests'))
from prepare_fixture import block


def sha(data): return hashlib.sha256(data).hexdigest()


def check():
    relative = Path('experiments/cluster/inference/Sources/ClusterInference/QwenResidentSoloEntry.swift')
    original = (BASE/'originals'/relative).read_text()
    changed = (BASE/'proposed'/relative).read_text()
    assert (OLD/'workspace'/relative).read_text() == original
    encoder = block(changed,'enum QwenResidentSoloOutput {')
    restored = changed[:changed.index('\n/// Bounds count JSON bytes, before the single framing LF.')]
    restored = restored.replace('publishSolo(report, maximumBytes: QwenResidentSoloOutput.finalMaximumBytes, check:',
                                'publishSolo(report, check:')
    restored = restored.replace('private func publishSolo<T: Encodable>(_ value: T,\n'
        '        maximumBytes: Int = QwenResidentSoloOutput.progressMaximumBytes, check: () throws -> Void) throws {',
        'private func publishSolo<T: Encodable>(_ value: T, check: () throws -> Void) throws {')
    restored = restored.replace('        let data = try QwenResidentSoloOutput.encode(value, maximumBytes: maximumBytes)\n'
        '        try check()', '        var data = try canonicalJSONData(value)\n'
        '        // Only CPU timing/token/metadata values; no tensor row or state payload.\n'
        '        guard !data.isEmpty, data.count <= 128 * 1024 else { throw ProbeError("Resident solo output exceeds its bound") }\n'
        '        data.append(10); try check()')
    assert restored == original
    assert changed.count('maximumBytes: QwenResidentSoloOutput.finalMaximumBytes') == 1
    assert 'static let progressMaximumBytes = 128 * 1024' in encoder
    assert 'static let finalMaximumBytes = 512 * 1024' in encoder
    current = {str(p.relative_to(BASE/'run-template')):p for p in (BASE/'run-template').rglob('*.py')}
    old = {str(p.relative_to(OLD/'run-template')):p for p in (OLD/'run-template').rglob('*.py')}
    assert current.keys() == old.keys()
    for name,p in current.items():
        raw = p.read_bytes()
        if name == 'solo_contract.py':
            raw = raw.replace(b"len(raw) <= 512*1024, 'Solo report bound'",b"len(raw) <= 128*1024, 'Solo report bound'")
        assert raw == old[name].read_bytes(), name
    generated = BASE/'Tests/generated'
    fixture = json.loads((generated/'preparation.json').read_bytes())
    dto = (generated/'ExactDTOs.swift').read_text()
    assert sha(dto.encode()) == fixture['exactDTOsSHA256']
    assert sha((generated/'cases.json').read_bytes()) == fixture['casesSHA256']
    for filename,pin in fixture['sources'].items():
        raw = Path(filename).read_bytes()
        assert len(raw) == pin['bytes'] and sha(raw) == pin['sha256'], filename
    for row in fixture['declarations']:
        prefix = 'public ' if row['type']=='QwenGatedDeltaWarmupObservation' else ''
        declaration = block(Path(row['source']).read_text(),prefix+'struct '+row['type']+':')
        assert sha(declaration.encode()) == row['fullDeclarationSHA256']
        stops = [declaration.index(mark) for mark in ('\n    init(', '\n    static func ', '\n    func ') if mark in declaration]
        fields = declaration[:min(stops)].rstrip()+'\n}' if stops else declaration
        expected = fields.replace(': Encodable {',': Encodable, Decodable {',1)
        assert sha(fields.encode()) == row['exactStoredDeclarationSHA256']
        assert block(dto,prefix+'struct '+row['type']+':') == expected
    assert block(dto,'enum QwenResidentSoloOutput {') == encoder
    assert sha(encoder.encode()) == fixture['realBoundedEncoderSHA256']
    assert 'import MLX' not in dto and 'GPU.' not in dto and 'Memory.' not in dto
    for name in ('prepare.py','owned_process.py'):
        assert (BASE/name).read_bytes() == (OLD/name).read_bytes()
    files = [*BASE.glob('*.py'), *current.values(), * (BASE/'Tests').glob('*.py')]
    for p in files: ast.parse(p.read_text(),filename=str(p))
    sources,deps,expected,changed_paths = authority()
    assert changed_paths == [str(relative)]
    assert len(sources) == len(expected) == 3293 and len(deps) == 9502
    return dict(sourceInverseExact=True,parentFinalConstantOnly=True,unchangedPythonHelpers=len(current)-1,
        exactStoredFieldDeclarations=len(fixture['declarations']),actualEncoderExact=True,
        preparedSourceMembers=len(expected),dependencyMembers=len(deps),changedNativePaths=changed_paths,
        originalOwnedHelperExact=True,compiled=False,modelOrKernelExecuted=False)


if __name__ == '__main__': print(json.dumps(check(),sort_keys=True))
