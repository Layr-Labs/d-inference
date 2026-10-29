#!/usr/bin/env python3
"""Pin and source preservation replay only. No compiler, fixtures or edits."""
import hashlib,json,re,struct
from pathlib import Path
B=Path(__file__).resolve().parent
R=B.parent
H=lambda b:hashlib.sha256(b).hexdigest()
def main():
 manifest=json.loads((B/'manifest.json').read_text())
 for x in manifest['members']:
  data=(B/x['path']).read_bytes();assert len(data)==x['bytes'] and H(data)==x['sha256'],x['path']
 lineage=json.loads((B/'lineage.json').read_text())
 for package,key in [('cluster-product-app-attest-identity-20260920','identityManifestSHA256'),('cluster-product-coordinator-composition-20260920','goCompositionManifestSHA256'),('cluster-product-swift-initiation-composition-20260920','swiftInitiationManifestSHA256')]:
  assert H((R/package/'manifest.json').read_bytes())==lineage[key],package
 workspace=Path(lineage['workspace']);virtual={}
 def current(path):
  if path in virtual:return virtual[path]
  p=workspace/path
  return p.read_bytes() if p.exists() else None
 for key in ['goLayer','swiftLayer']:
  path=Path(lineage[key]);root=path.parent
  for x in json.loads(path.read_text()):
   data=current(x['path']);before=H(data) if data is not None else None
   assert before in (x['beforeSHA256'],x['sha256']),x['path']
   source=Path(x['sourcePath']) if 'sourcePath' in x else root/'proposed'/x['path']
   after=source.read_bytes();assert H(after)==x['sha256'] and len(after)==x['bytes'];virtual[x['path']]=after
 rows=json.loads((B/'overlay.json').read_text())
 for x in rows:
  out=(B/'proposed'/x['path']).read_bytes();assert len(out)==x['bytes'] and H(out)==x['sha256'],x['path']
  data=current(x['path']);assert (H(data) if data is not None else None)==x['beforeSHA256'],x['path']
  if data is not None:assert data==(B/'original'/x['path']).read_bytes(),x['path']
 for x in json.loads((B/'unchanged-controls.json').read_text()):
  data=Path(x['sourcePath']).read_bytes();assert H(data)==x['sha256'] and len(data)==x['bytes'],x['path']
 old=(B/'original/coordinator/registry/verified_pair_membership.go').read_text()
 new=(B/'proposed/coordinator/registry/verified_pair_membership.go').read_text()
 def between(s,a,z):return s[s.index(a):s.index(z,s.index(a))]
 assert between(old,'func verifiedPairTranscript','\n// Existing pending')==between(new,'func verifiedPairLegacyTranscript','\n// Existing pending').replace('verifiedPairLegacyTranscript','verifiedPairTranscript',1)
 assert between(old,'\ta := p.AttestationResult','\nfunc freshVerifiedPairTime')==between(new,'\ta := p.AttestationResult','\nfunc freshVerifiedPairTime')
 for name,before,after in [('native_pair_handlers.go','s.membership.Members[rank].SEPublicKey','s.membership.Members[rank].controlPublicKey()'),('native_pair_intent.go','member.SEPublicKey','member.controlPublicKey()')]:
  path='coordinator/registry/'+name;a=(B/'original'/path).read_text();b=(B/'proposed'/path).read_text();assert a.count(before)==1 and b.replace(after,before)==a,name
 v=json.loads((B/'typed-vectors.json').read_text());put=lambda b:struct.pack('>I',len(b))+b
 head=b'darkbloom/coordinator-pair-membership/v2\0'+bytes([1])*16+struct.pack('>Q',9)+put(b'model')+bytes([4])*32+bytes([5])*32+put(b'aes256gcm-hkdf-sha256-v1')+struct.pack('>QQ',100,200)
 for label,kinds in [('mixedMembership',['legacy','appAttest']),('appAttestMembership',['appAttest','appAttest'])]:
  b=head+b''.join(bytes([rank])+put(bytes.fromhex(v[kind]['hex'])) for rank,kind in enumerate(kinds))
  assert len(b)==v[label]['bytes'] and H(b)==v[label]['sha256'] and b.hex()==v[label]['hex'],label
 found=[]
 for p in sorted((B/'proposed').rglob('*')):
  if p.name.endswith('_test.go'):
   found.extend({'path':str(p.relative_to(B/'proposed')),'name':n,'language':'Go'} for n in re.findall(r'^func (Test\w+)\(',p.read_text(),re.M))
  elif p.name.endswith('Tests.swift'):
   found.extend({'path':str(p.relative_to(B/'proposed')),'name':p.stem+'.'+n+'()','language':'Swift'} for n in re.findall(r'@Test func (\w+)\(',p.read_text()))
 assert found==json.loads((B/'staged-tests.json').read_text())['methods'] and len(found)==24
 print(json.dumps({'sourceReplay':'PASS','overlays':len(rows),'legacyTranscriptAndPredicatePreserved':True,'nativeSignatureAndIntentOneTokenInverse':True,'independentFieldVectors':2,'stagedGoMethods':21,'stagedSwiftMethods':3,'compilerExecuted':False,'fixturesExecuted':False}))
if __name__=='__main__':main()
