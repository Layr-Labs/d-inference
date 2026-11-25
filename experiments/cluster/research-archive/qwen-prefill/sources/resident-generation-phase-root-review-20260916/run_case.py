from pathlib import Path
import hashlib,json,os,sys
ROOT=Path(__file__).resolve().parent
DRAFT=ROOT.parent/'resident-generation-phase-physical-draft-20260916'
sys.path.insert(0,str(DRAFT/'Controller'))
from owned_process import invoke_controller
assert hashlib.sha256((DRAFT/'manifest.json').read_bytes()).hexdigest()=='e3c443a9f1982645bbafcd1fe8e7b25344a9594251341943d3d2d83a97d7b9bf'
case,phase,*rank=sys.argv[1:];assert case in ('serial','lookahead') and phase in ('copy','preflight','physical','collect','validate')
command=json.loads((DRAFT/'commands.json').read_bytes())['policies'][case][phase]
if phase in ('copy','preflight'):
 assert len(rank)==1 and rank[0] in ('0','1');command=command[int(rank[0])]
else:assert not rank
record={'case':case,'phase':phase,'argv':command};label='-'.join([case,phase]+rank)
seconds={'copy':210,'preflight':60,'physical':540,'collect':90,'validate':30}[phase]
os.umask(0o077)
with (ROOT/(label+'-outer-1.json')).open('x') as receipt:
 try:
  with (ROOT/(label+'-outer-1.stdout')).open('xb') as out,(ROOT/(label+'-outer-1.stderr')).open('xb') as err:invoke_controller(command,out,err,record,timeout=seconds)
 finally:json.dump(record,receipt,indent=2);receipt.write('\n')
assert record['exitCode']==0 and record['reaped'] and record['groupAbsent']
print(json.dumps(record),flush=True)
