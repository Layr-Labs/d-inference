"""Selected-source/pin checks only. No compiler, model, native or network calls."""
from pathlib import Path
import hashlib
import json
import re

BASE = Path(__file__).resolve().parent
MAIN = Path('/Users/developer/DarkbloomDev/d-inference')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check():
    composition = json.loads((BASE / 'native-build-composition.json').read_bytes())
    ancestor = Path(composition['ancestor'])
    for name, digest in composition['ancestryMetadata'].items():
        assert sha(ancestor / name) == digest, name
    assert sha(Path(composition['helper']['path'])) == composition['helper']['sha256']
    by = {r['path']: r for r in json.loads((ancestor / 'source-snapshot-1.json').read_bytes())['members']}
    selected = set()
    for row in composition['overlays']:
        assert row['path'] not in selected
        selected.add(row['path'])
        assert by.get(row['path'], {}).get('sha256') == row['beforeSHA256'], row['path']
        assert sha(BASE / row['source']) == row['afterSHA256'], row['path']
    for row in composition['exclusions']:
        assert by[row['path']]['sha256'] == row['beforeSHA256'], row['path']
    for row in composition['controls']:
        assert row['mainSHA256'] == row['ancestorSHA256'] == by[row['path']]['sha256']
        assert sha(MAIN / row['path']) == row['mainSHA256'], row['path']
    for row in json.loads((BASE / 'input-origins.json').read_bytes()):
        assert sha(Path(row['source'])) == row['sha256'], row['source']
        if row.get('byteExactPrerequisite'):
            assert sha(BASE / 'proposed' / row['path']) == row['sha256']
        else:
            assert sha(BASE / 'originals' / row['path']) == row['sha256']
    for row in json.loads((BASE / 'main-preimages.json').read_bytes())['files']:
        p = MAIN / row['path']
        assert (sha(p) if p.exists() else None) == row['beforeSHA256'], row['path']
    schema = json.loads((BASE / 'description-schema.json').read_bytes())
    source = BASE / schema['producer']
    assert sha(source) == schema['producerSHA256']
    fragment = source.read_text().split('var result =', 1)[1].split('] as [String: Any]', 1)[0]
    fields = re.findall(r'"([a-zA-Z][a-zA-Z0-9]*)":', fragment)
    assert len(fields) == len(set(fields)) == 26 and set(fields) == set(schema['fields'])
    tests = list((BASE / 'proposed').glob('**/*Tests.swift'))
    methods = sum(len(re.findall(r'func test\w+\(', p.read_text())) for p in tests)
    assert methods == 18
    return dict(selectedOverlays=len(selected), excludedProbeFiles=len(composition['exclusions']),
                unchangedControls=len(composition['controls']), stagedTestMethods=methods,
                descriptorFields=26, compilerExecuted=False, testsExecuted=False,
                nativeExecuted=False, remoteExecuted=False, mainChanged=False)


if __name__ == '__main__':
    print(json.dumps(check(), sort_keys=True))
