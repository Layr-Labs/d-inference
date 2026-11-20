"""Small-source equality, declared inverses and syntax only; no compiler/fixture/IO probe."""
from pathlib import Path
import ast, difflib, hashlib, json
BASE=Path(__file__).resolve().parent

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def check():
    spec=json.loads((BASE/'source-inputs.json').read_bytes());old=Path(spec['ancestor'])
    for key in ['sourceSnapshot','dependencySnapshot']:
        row=spec[key]
        if sha(Path(row['path']))!=row['sha256']:raise ValueError('Snapshot authority changed')
    before={x['path']:x for x in json.loads(Path(spec['sourceSnapshot']['path']).read_bytes())['members']}
    patch=''
    for row in spec['overlays']:
        rel=row['path'];p=BASE/'proposed'/rel;o=BASE/'original'/rel
        if row['after']!={'bytes':p.stat().st_size,'sha256':sha(p)}:raise ValueError('Overlay differs: '+rel)
        if row['before'] is None:
            if rel in before or o.exists():raise ValueError('New destination exists: '+rel)
        elif row['before']!={k:before[rel][k] for k in ['bytes','sha256']} or o.read_bytes()!=(old/rel).read_bytes():
            raise ValueError('Preimage differs: '+rel)
        patch+=''.join(difflib.unified_diff(o.read_text().splitlines(True) if o.exists() else [],p.read_text().splitlines(True),fromfile='a/'+rel if o.exists() else '/dev/null',tofile='b/'+rel))
    if patch!=(BASE/'runtime.patch').read_text():raise ValueError('Source inverse patch differs')
    for row in spec['unchangedControls']:
        p=old/row['path']
        if p.stat().st_size!=row['bytes'] or sha(p)!=row['sha256']:raise ValueError('Core control changed')
    copies=json.loads((BASE/'unchanged-inputs.json').read_bytes())
    for row in copies:
        p=BASE/row['local'];q=Path(row['source'])
        if p.stat().st_size!=row['bytes'] or sha(p)!=row['sha256'] or p.read_bytes()!=q.read_bytes():
            raise ValueError('Unchanged fixture/helper copy differs')
    if (BASE/'validate_phase_memory.py').read_bytes()!=(BASE/'Experiment/validate_phase_memory.py').read_bytes():
        raise ValueError('Physical validator differs from staged fixture validator')
    physical_patch=''
    for name in ['collect.py','physical_evidence.py','validate_run.py']:
        a=BASE/'original'/('physical-'+name);b=BASE/'Experiment'/name
        physical_patch+=''.join(difflib.unified_diff(a.read_text().splitlines(True),b.read_text().splitlines(True),fromfile='ancestor/'+name,tofile='observer/'+name))
    if physical_patch!=(BASE/'Experiment/evidence.patch').read_text():raise ValueError('Physical helper inverse differs')
    for row in json.loads((BASE/'Experiment/input-pins.json').read_bytes()):
        p=Path(row['path'])
        if p.stat().st_size!=row['bytes'] or sha(p)!=row['sha256']:raise ValueError('Prospective reference/experiment input changed')
    parsed=[]
    for p in sorted(BASE.rglob('*.py')):
        if not any(x in p.parts for x in ['workspace','__pycache__']):
            ast.parse(p.read_text());parsed.append(str(p.relative_to(BASE)))
    methods={}
    for name,count in [('test_memory_schema.py',8),('test_experiment.py',4)]:
        tree=ast.parse((BASE/'Tests'/name).read_text())
        methods[name]=sum(isinstance(x,ast.FunctionDef) and x.name.startswith('test_') for x in ast.walk(tree))
        if methods[name]!=count:raise ValueError('Staged CPU fixture membership differs')
    return dict(sourceOnly=True,overlays=len(spec['overlays']),newSources=sum(x['before'] is None for x in spec['overlays']),
        unchangedControls=len(spec['unchangedControls']),exactCopiedFixturesAndHelpers=len(copies),
        pythonASTFiles=len(parsed),stagedPythonMethods=methods,compilerOrFixturesOrModelsExecuted=False)
if __name__=='__main__':print(json.dumps(check(),sort_keys=True))
