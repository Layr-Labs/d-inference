"""Read-only source/bundle check. No compiler, native executable or network."""
import ast
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def main():
    lineage = json.loads((BASE / 'lineage.json').read_text())
    changed = {'Sources/ConfiguredOwner.swift', 'recording-worker/NativeWorkerRuntime.swift'}
    checked = []
    for item in lineage['sourceCopies']:
        if item['path'] in changed:
            continue
        data = (BASE / item['path']).read_bytes()
        assert len(data) == item['bytes'] and hashlib.sha256(data).hexdigest() == item['sha256'], item['path']
        checked.append(item['path'])
    original = (BASE / 'originals/ConfiguredOwner.swift').read_text()
    owner = (BASE / 'Sources/ConfiguredOwner.swift').read_text()
    owner = owner.replace('value.stageCut == Qwen27BQualificationScope.stageCut', '[4, 8, 12, 16].contains(value.stageCut)')
    owner = owner.replace('try Qwen27BQualificationScope.validate(ready)\n', '')
    assert owner == original
    old = (BASE / 'originals/recording-NativeWorkerRuntime.swift').read_text()
    new = (BASE / 'recording-worker/NativeWorkerRuntime.swift').read_text()
    new = new.replace('        guard selected == .serial else {\n'
                      '            throw WorkerFailure.invalid("27B native validation requires serial recording")\n'
                      '        }\n', '')
    assert new == old
    for file in BASE.glob('*.py'):
        ast.parse(file.read_text(), filename=str(file))
    request = json.loads((BASE / 'inputs/request.json').read_text())
    prompt = (BASE / 'inputs/prompt.ids.json').read_bytes()
    assert request['promptFileSHA256'] == hashlib.sha256(prompt).hexdigest()
    assert len(json.loads(prompt)) == request['promptCount'] == 32
    assert (request['chunkSize'], request['outputCount'], request['stageCut']) == (16, 128, 32)
    assert request['stopTokenIDs'] == [] and request['mtp'] is False
    print(json.dumps(dict(schema='qwen27b_owner_qualification_source_check_v1', passed=True,
        exactCopiedMembers=len(checked), exactOwnerInverse=True, exactRecordingInverse=True,
        pythonSyntaxOnly=True, promptPacketMatched=True, swiftCompiled=False,
        nativeExecuted=False, modelPayloadRead=False, remoteOperations=False), sort_keys=True))


if __name__ == '__main__':
    main()
