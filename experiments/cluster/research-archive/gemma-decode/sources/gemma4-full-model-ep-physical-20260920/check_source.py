"""Source-only pins, copy inverses and Python syntax; never import/run the candidate."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parent
def sha(raw):return hashlib.sha256(raw).hexdigest()
def main():
    manifest=json.loads((ROOT/'source-inputs.json').read_bytes())
    assert manifest['schema']=='gemma4_full_expert_physical_source_v1'
    names=set()
    for row in manifest['files']:
        name=row['path'];assert name not in names and '..' not in Path(name).parts and not Path(name).is_absolute()
        names.add(name);path=ROOT/name
        assert path.is_file() and not path.is_symlink() and path.stat().st_size<=2_000_000
        raw=path.read_bytes();assert (len(raw),sha(raw))==(row['bytes'],row['sha256']),name
    lineage=json.loads((ROOT/'helper-lineage.json').read_bytes());patch=[];unchanged=changed=0
    for row in lineage['copies']:
        path=ROOT/row['destination'];old=ROOT/'originals'/row['destination']
        source=old if old.exists() else path
        assert sha(source.read_bytes())==row['sha256'],row['destination']
        if old.exists():
            changed+=1
            patch.extend(difflib.unified_diff(old.read_text().splitlines(True),path.read_text().splitlines(True),
                fromfile='a/'+row['destination'],tofile='b/'+row['destination']))
        else:unchanged+=1
    assert ''.join(patch)==(ROOT/'runtime.patch').read_text(),'Exact six-helper diff'
    extraction=lineage['extraction'];source=Path(extraction['source']).read_bytes()
    assert sha(source)==extraction['sha256'],'Qualified evidence reader source'
    text=source.decode();body=text[text.index(extraction['first']):text.index(extraction['after'])].rstrip()+'\n'
    actual=(ROOT/extraction['destination']).read_text();actual=actual[actual.index(extraction['first']):].rstrip()+'\n'
    assert body==actual and sha(body.encode())==extraction['bodySHA256'],'Journal/process/clock exact extraction'
    inputs=json.loads((ROOT/'binding-inputs.json').read_bytes())
    for row in inputs['sourcePackages']+[inputs['metadataAndPromptSources'],inputs['resourceLineage']]:
        path=Path(row['path']);assert path.stat().st_size<=2_000_000 and sha(path.read_bytes())==row['sha256'],str(path)
    python=embedded=0
    for name in sorted(names):
        if not name.endswith('.py'):continue
        python+=1;tree=ast.parse((ROOT/name).read_text(),filename=name)
        for node in tree.body:
            if isinstance(node,ast.Assign) and isinstance(node.value,ast.Constant) and isinstance(node.value.value,str):
                if any(isinstance(target,ast.Name) and target.id in ('INSTALL','CREATE','QUIESCENT','CANCEL') for target in node.targets):
                    ast.parse(node.value.value,filename=name+':remote');embedded+=1
    tree=ast.parse((ROOT/'Tests/test_contract.py').read_text())
    tests=[node.name for node in ast.walk(tree) if isinstance(node,ast.FunctionDef) and node.name.startswith('test_')]
    assert len(tests)==8
    print(json.dumps(dict(sourceOnly=True,files=len(names),pythonFiles=python,embeddedPrograms=embedded,
        exactCopiedHelpers=unchanged,changedHelpers=changed,stagedUnexecutedTests=tests),sort_keys=True))
if __name__=='__main__':main()
