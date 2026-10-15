import ast,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
def require_pin(path,row):
    raw=path.read_bytes()
    assert not path.is_symlink() and len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256'],str(path)
manifest=json.loads((ROOT/'source-inputs.json').read_bytes())
for row in manifest['members']:require_pin(ROOT/row['path'],row)
composition=json.loads((ROOT/'composition.json').read_bytes())
for key in ['harnessPredecessor','nativeDepthSource']:
    row=composition[key];require_pin(Path(row['path']),row)
for row in composition['files']:
    require_pin(Path(row['before']['path']),row['before'])
    require_pin(ROOT/'preimages'/row['path'],row['before'])
    require_pin(ROOT/row['source'],row['after'])
    tree=ast.parse((ROOT/row['source']).read_text(),filename=row['path'])
    for node in tree.body:
        if isinstance(node,ast.Assign) and any(isinstance(x,ast.Name) and x.id=='BODY' for x in node.targets):
            ast.parse(ast.literal_eval(node.value),filename=row['path']+':BODY')
for p in (ROOT/'Tests').glob('*.py'):ast.parse(p.read_text(),filename=str(p))
print(json.dumps(dict(status='passed',sourceOnly=True,overlays=len(composition['files']),nativeExecuted=False,testsExecuted=False)))
