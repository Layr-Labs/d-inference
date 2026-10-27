"""Small source/pin checks only; no workspace enumeration, native or compiler."""
import ast, hashlib, json
from pathlib import Path

BASE = Path(__file__).resolve().parent
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    inputs = json.loads((BASE / 'inputs.json').read_bytes())
    for row in inputs['pins']:
        path = Path(row['path'])
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Small input pin changed: ' + str(path))
    for row in inputs['overlays']:
        if sha(BASE / row['source']) != row['afterSHA256']: raise ValueError('Overlay changed')
    name = 'CBv2RequestGeometry+Attention.swift'
    old = (BASE / 'originals' / name).read_text(); new = (BASE / 'proposed' / name).read_text()
    a = 'guard kind.modelLayerIndex == index, kind.sharesKVWithLayer == nil,'
    b = 'guard (kind.modelLayerIndex ?? index) == index, kind.sharesKVWithLayer == nil,'
    if old.count(a) != 1 or new.replace(b, a) != old: raise ValueError('Geometry inverse differs')
    name = 'Gemma4ShortCheckEntry.swift'
    block = '        if arguments == ["--check-attention-identity", "cpu"] {\n            return try Gemma4AttentionIdentityCheck.run()\n        }\n'
    old = (BASE / 'originals' / name).read_text(); new = (BASE / 'proposed' / name).read_text()
    if new.count(block) != 1 or new.replace(block, '') != old: raise ValueError('Execution entry inverse differs')
    python = list(BASE.glob('*.py'))
    for path in python: ast.parse(path.read_text(), filename=str(path))
    print(json.dumps(dict(pythonAST=len(python), inputPins=len(inputs['pins']), overlays=3,
        geometryInverse=True, existingExecuteEntryInverse=True,
        nativeControlsExecuted=False, compilerExecuted=False, workspaceModified=False), sort_keys=True))

if __name__ == '__main__': main()
