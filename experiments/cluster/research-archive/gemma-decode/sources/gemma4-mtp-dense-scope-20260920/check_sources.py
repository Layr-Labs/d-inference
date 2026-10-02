#!/usr/bin/env python3
"""Small-file source check only. No compiler, native process, model or remote IO."""
from pathlib import Path
import ast,difflib,hashlib,json,re
ROOT=Path(__file__).resolve().parent

def digest(path):
    assert path.is_file() and not path.is_symlink(),str(path)
    assert path.stat().st_size < 600_000,str(path)
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    manifest=json.loads((ROOT/'manifest.json').read_text())
    for row in manifest['members']:
        p=ROOT/row['path']
        assert digest(p)==row['sha256'] and p.stat().st_size==row['bytes'],str(p)
    value=json.loads((ROOT/'composition.json').read_text())
    assert len(value['overlays'])==7 and len(value['additions'])==2
    targets=[];patch=''
    for row in value['overlays']:
        before=ROOT/row['preimage'];after=ROOT/row['source']
        assert digest(before)==row['beforeSHA256'] and digest(after)==row['sha256']
        patch+=''.join(difflib.unified_diff(before.read_text().splitlines(True),after.read_text().splitlines(True),fromfile='a/'+row['target'],tofile='b/'+row['target']))
        targets.append(row['target'])
    assert patch==(ROOT/'runtime.patch').read_text()
    for row in value['additions']:
        assert digest(ROOT/row['source'])==row['sha256'] and row['mustBeAbsent'] is True
        targets.append(row['target'])
    assert len(targets)==len(set(targets))
    lineage=json.loads((ROOT/'lineage.json').read_text())
    for row in lineage['context']:
        assert digest(Path(row['path']))==row['sha256'],row['path']
    for key,count in [('densePrimitive',108),('gatheredPrimitive',288)]:
        receipt=json.loads(Path(lineage[key]['path']).read_text())
        assert receipt['status']=='passed' and receipt['actualPrimitiveCases']==count
        assert receipt['nativeSHA256']==lineage['qualifiedPrimitiveNativeSHA256']
        assert receipt['modelNumericalCorrectnessQualified'] is False
    labels=[]
    for row in value['optionalTests']:
        assert digest(ROOT/row['source'])==row['sha256']
        labels+=re.findall(r'func (test\w+)\(', (ROOT/row['source']).read_text())
    assert len(labels)==len(set(labels))==7
    scope=(ROOT/'SDK/QuantizedProjectionScope.swift').read_text()
    assert 'if box.failure == nil { box.failure = error }' in scope
    assert 'box.handler = nil' in scope and 'withoutActuallyEscaping(handler)' in scope
    projection=(ROOT/'Runtime/Gemma4MTPDenseProjection.swift').read_text()
    assert 'GemmaSmallGatherQMV' not in projection and 'if width == 1 { return try body() }' in projection
    ast.parse(Path(__file__).read_text())
    print(json.dumps(dict(status='passed',sourceMembers=len(manifest['members']),overlays=7,additions=2,exactPatchReplays=7,contextPins=len(lineage['context']),stagedTestMethods=7,compilerExecuted=False,nativeExecuted=False),sort_keys=True))
if __name__=='__main__': main()
