import os,signal,json,hashlib,time,stat
signal.alarm(8)
p='/Users/developer/.darkbloom/daemon-state.json'
r={'path':p,'observedAt':time.time()}
try:
 fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
 try:
  st=os.fstat(fd)
  if not stat.S_ISREG(st.st_mode) or st.st_size>1048576: raise ValueError('not bounded regular state')
  raw=os.read(fd,1048577)
  if len(raw)>1048576:raise ValueError('state bound exceeded')
 finally:os.close(fd)
 x=json.loads(raw);r.update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
 for k in ('schema','pid','version','written_at','started_at','process_identity','inference_active'):
  if k in x:r[k]=x[k]
 key=x.get('attestation_public_key')
 r['attestationPublicKeyPresent']=isinstance(key,str) and bool(key)
 if r['attestationPublicKeyPresent']:r['sePublicKeySHA256']=hashlib.sha256(key.encode()).hexdigest()
 trust=x.get('trust')
 if isinstance(trust,dict):r['trust']={k:trust[k] for k in ('trust_level','status','received_at') if k in trust}
except FileNotFoundError:r['missing']=True
print(json.dumps(r,sort_keys=True))
