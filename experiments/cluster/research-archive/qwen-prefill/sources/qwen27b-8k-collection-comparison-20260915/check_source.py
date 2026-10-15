"""Check the prospective bindings and exact unchanged transport closure."""
import ast
import hashlib
import json
from pathlib import Path
import prepare_packet as helper

BASE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    helper.bootstrap()
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    previous = BASE.parent / 'qwen27b-cut16-collection-comparison-20260915'
    helper.verify_package(previous, lineage['baseManifestSHA256'])
    for name, expected in lineage['originals'].items():
        assert digest(BASE / 'originals' / name) == digest(previous / name) == expected
    for name, expected in lineage['runtimePins'].items():
        assert digest(BASE / name) == expected
    assert (BASE / 'collect_sidecars.py').read_bytes() == (BASE / 'originals/collect_sidecars.py').read_bytes()
    old_reader = (BASE / 'originals/read_sidecar_remote.py').read_text()
    reader = (BASE / 'read_sidecar_remote.py').read_text()
    assert reader.replace('qwen27b-8k-serial-owner-validation-20260915/evidence/c7517799-2a77-49fa-af9c-2b4f662bf76c.json',
                          'qwen27b-cut16-owner-validation-20260915/evidence/20801ced-ca29-4faf-b71a-9ebbe1886a14.json') == old_reader
    assert helper.COMPARATOR_SHA == 'f3757094f14cc479e761b83b2a988551250bd61a9dba1797e91c3e564f29aebe'
    assert helper.PARENT_SHA == 'c479d8277855431bf3acfd0a9310fcd23ada9ee6cf84c741323a24a625f9fcd2'
    assert helper.AGREEMENT_SHA == '5964b5f1e865fe2d12f3146ff600b0675db24d427ff979f8bde72c24b309172e'
    for _, (name, expected, _) in helper.SOURCE_ROLES.items():
        assert digest(helper.PARENT / name) == expected
    from audit_common import agreement, request_context
    from audit_scope import pinned_scope
    request = json.loads((helper.PARENT / 'inputs/request.json').read_bytes())
    scope = pinned_scope(request, json.loads((helper.PARENT / 'provenance/recording-metadata.json').read_bytes()))
    context = request_context((helper.PARENT / 'inputs/prompt.ids.json').read_bytes(), request['requestID'], scope)
    agreement(json.loads((helper.PARENT / 'expected-agreement.json').read_bytes()), context)
    assert (scope.prompt, scope.chunk, scope.output, scope.cut, scope.frames, scope.frontier) == (8192,512,128,16,143,8319)
    assert request['requestID'] == 'c7517799-2a77-49fa-af9c-2b4f662bf76c'
    for path in BASE.glob('*.py'):
        ast.parse(path.read_text())
    result = dict(status='passed', parentManifestSHA256=helper.PARENT_SHA,
        comparatorManifestSHA256=helper.COMPARATOR_SHA, agreementSHA256=helper.AGREEMENT_SHA,
        collectorExact=True, readerOnlyFixedPathChanged=True, referenceInputRequired=True,
        sourceGeometry=[8192,512,128,16,143,8319], actualReferenceRead=False, actualCandidateRead=False,
        remoteOperations=False, modelExecuted=False)
    print(json.dumps(result, sort_keys=True, indent=2))


if __name__ == '__main__':
    main()
