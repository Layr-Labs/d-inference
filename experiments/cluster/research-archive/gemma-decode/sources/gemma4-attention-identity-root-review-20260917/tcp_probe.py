import sys,json,hashlib,shlex
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCE=ROOT.parent/'gemma4-attention-identity-physical-draft-20260917'
sys.path[:0]=[str(SOURCE),str(SOURCE/'source')]
from check_process import run_owned
from parent_settings import SSH
role=sys.argv[1];assert role in ('server','client')
base=ROOT/'tailscale-rendezvous-probe-1';base.mkdir(mode=0o700,exist_ok=True)
out=base/role;out.mkdir(mode=0o700)
if role=='client':
 first=(base/'server/network.stdout').read_bytes().splitlines()[0]
 assert json.loads(first)=={'ready':True,'address':'192.0.2.250','port':51361}
code="""import socket,signal,json,sys
signal.signal(signal.SIGALRM,lambda *_:sys.exit(124));signal.alarm(12)
role=sys.argv[1];message=b'darkbloom-public-rendezvous-probe-v1';address='192.0.2.250';port=51361
def receive(s,n):
 result=b''
 while len(result)<n:
  block=s.recv(n-len(result))
  if not block:raise ValueError('Unexpected EOF')
  result+=block
 return result
if role=='server':
 with socket.socket() as listener:
  listener.settimeout(10);listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind((address,port));listener.listen(1)
  print(json.dumps(dict(ready=True,address=address,port=port)),flush=True)
  connection,peer=listener.accept()
  with connection:
   connection.settimeout(3)
   assert peer[0]=='192.0.2.223'
   assert receive(connection,len(message))==message
   connection.sendall(message[::-1]);connection.shutdown(socket.SHUT_WR)
   assert connection.recv(1)==b''
else:
 with socket.create_connection((address,port),timeout=5) as connection:
  connection.sendall(message);connection.shutdown(socket.SHUT_WR)
  assert receive(connection,len(message))==message[::-1]
  assert connection.recv(1)==b''
signal.alarm(0)
print(json.dumps(dict(passed=True,role=role,bytes=len(message),nativeOrModelExecuted=False,networkConfigurationChanged=False)),flush=True)
"""
host='darkbloom-24' if role=='server' else 'darkbloom-48'
r=run_owned(SSH+[host,shlex.join(['/usr/bin/python3','-B','-c',code,role])],out,'network',20)
assert (out/'network.stderr').read_bytes()==b''
rows=[json.loads(x) for x in (out/'network.stdout').read_bytes().splitlines()]
assert rows[-1]==dict(passed=True,role=role,bytes=36,nativeOrModelExecuted=False,networkConfigurationChanged=False)
r.update(status='passed',publicTCPProbeOnly=True,modelExecuted=False)
with (out/'receipt.json').open('x') as f:json.dump(r,f,indent=2,sort_keys=True);f.write('\n')
print(json.dumps(dict(status='passed',role=role,receiptSHA256=hashlib.sha256((out/'receipt.json').read_bytes()).hexdigest())))
