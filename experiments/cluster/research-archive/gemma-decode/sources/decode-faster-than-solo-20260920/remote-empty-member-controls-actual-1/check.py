import ast,hashlib,json,sys
from pathlib import Path
R=Path('/Users/developer/DarkbloomDev/cluster-research');D=Path(__file__).resolve().parent
names=['gemma4-mtp-remote-dense-numerical-empty-20260920','gemma4-mtp-remote-packed-head-numerical-empty-20260920']
sys.path.insert(0,str(R/names[0]));import numeric_reader as n
loops=[]
for name in names:
 tree=ast.parse((R/name/'compare.py').read_bytes())
 compare=next(x for x in tree.body if isinstance(x,ast.FunctionDef) and x.name=='compare')
 loop=next(x for x in compare.body if isinstance(x,ast.For) and isinstance(x.iter,ast.Subscript) and isinstance(x.iter.slice,ast.Constant) and x.iter.slice.value=='members')
 loops.append(ast.dump(loop.body[0:][0],include_attributes=False))
 code=compile(ast.Module(body=loop.body,type_ignores=[]),str(R/name/'compare.py'),'exec')
 root=D/name;root.mkdir();p=root/'member';p.write_bytes(b'')
 def check(row):
  inputs=n.Inputs();exec(code,dict(inputs=inputs,n=n,remote_root=root,row=row));inputs.recheck()
 check(dict(path='member',bytes=0,sha256=n.digest(b'')))
 try:check(dict(path='member',bytes=1,sha256=n.digest(b'x')))
 except ValueError:pass
 else:raise AssertionError('unexpected empty nonzero member accepted')
 p.write_bytes(b'x')
 try:check(dict(path='member',bytes=0,sha256=n.digest(b'')))
 except ValueError:pass
 else:raise AssertionError('nonempty declared-zero member accepted')
assert loops[0]==loops[1]
print(json.dumps(dict(status='passed',variants=2,controlsPerVariant=3,declaredEmptyAccepted=True,unexpectedEmptyRefused=True,nonemptyZeroDeclarationRefused=True,sidecarsRead=False,nativeExecuted=False)))
