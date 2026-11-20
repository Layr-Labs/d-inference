from pathlib import Path
import hashlib,json,os,sys
ROOT=Path(__file__).resolve().parent
DRAFT=ROOT.parent/'resident-generation-phase-physical-draft-20260916'
sys.path.insert(0,str(DRAFT/'Controller'))
from owned_process import invoke_controller
assert hashlib.sha256((DRAFT/'manifest.json').read_bytes()).hexdigest()=='e3c443a9f1982645bbafcd1fe8e7b25344a9594251341943d3d2d83a97d7b9bf'
name,=sys.argv[1:]
commands=json.loads((DRAFT/'commands.json').read_bytes())
assert name in ('controllerBuild','joinTests','bind','artifacts')
argv=commands[name]
if name=='bind':
 p=DRAFT/'Controller/build-1/receipt.json';assert json.loads(p.read_bytes())['passed'];argv[-1]=hashlib.sha256(p.read_bytes()).hexdigest()
seconds={'controllerBuild':250,'joinTests':45,'bind':120,'artifacts':60}[name]
os.umask(0o077);record={'phase':name,'argv':argv}
with (ROOT/(name+'-outer-1.json')).open('x') as result:
 try:
  with (ROOT/(name+'-outer-1.stdout')).open('xb') as out,(ROOT/(name+'-outer-1.stderr')).open('xb') as err:invoke_controller(argv,out,err,record,timeout=seconds)
 finally:json.dump(record,result,indent=2);result.write('\n')
assert record['exitCode']==0 and record['reaped'] and record['groupAbsent']
print(json.dumps(record),flush=True)
