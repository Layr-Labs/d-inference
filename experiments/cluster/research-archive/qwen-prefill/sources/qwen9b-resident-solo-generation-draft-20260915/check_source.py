"""Small local source/input checks only; no model, compiler, subprocess or network."""
from pathlib import Path
import ast
import difflib
import json
from prepare_build import DRAFT, PACKAGE, digest, verify_source


def main():
    integration, origin, base = verify_source()
    for source in DRAFT.glob('*.py'):
        ast.parse(source.read_text(), filename=str(source))
    expected_patch = ''
    for row in integration['files']:
        old = (origin / row['target']).read_text() if row['baseSHA256'] else ''
        new = (DRAFT / row['source']).read_text()
        expected_patch += ''.join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
            fromfile='a/' + row['target'], tofile='b/' + row['target']))
    assert expected_patch == (DRAFT / 'runtime.patch').read_text()
    assert (DRAFT / 'Sources/SoloDeviceExclusion/ClusterDeviceExclusion.swift').read_bytes() == Path(integration['base']['gateSource']).read_bytes()
    packet = json.loads((DRAFT / 'inputs/request.json').read_bytes())
    prompt = DRAFT / 'inputs/prompt.ids.json'; expected = DRAFT / 'inputs/expected-token-ids.json'
    assert digest(prompt) == packet['promptFileSHA256'] == 'ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997'
    assert digest(expected) == packet['expectedTokenFileSHA256']
    config = Path(packet['expectedIDsSource']); assert digest(config) == packet['expectedIDsSourceSHA256']
    values = json.loads(config.read_bytes())
    assert json.loads(prompt.read_bytes()) == values['promptTokenIDs'] and len(values['promptTokenIDs']) == 8192
    assert json.loads(expected.read_bytes()) == values['expectedTokenIDs'] and len(values['expectedTokenIDs']) == 128
    assert (values['chunkSize'], values['outputCount'], values['stopTokenIDs'], values['warmupCount'], values['measuredCount']) == (512,128,[],1,3)
    assert digest(DRAFT / 'Tests/retained-inputs.json') == '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25'
    record = {'schema': 'resident_solo_source_checks_v1', 'status': 'passed', 'baseSourceFilesVerified': len(base),
        'overlayTargetsVerified': len(integration['files']), 'patchReproduced': True, 'sharedGateByteExact': True,
        'matchedPromptAndExpectedSequenceVerified': True, 'pythonSourcesParsed': True,
        'swiftCompileOrTestsExecuted': False, 'modelOrKernelExecuted': False,
        'mainModified': False, 'remoteOperations': False}
    target = DRAFT / 'source-checks.json'
    assert not target.exists(), 'Retain each source check receipt without replacement'
    target.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print(json.dumps(record, sort_keys=True))


if __name__ == '__main__':
    main()
