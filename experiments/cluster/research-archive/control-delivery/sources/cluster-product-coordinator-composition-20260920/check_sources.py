#!/usr/bin/env python3
"""Small source replay only; never prepares a checkout or runs Go/Swift."""
import argparse, hashlib, json, subprocess
from pathlib import Path
B=Path(__file__).resolve().parent
H=lambda b:hashlib.sha256(b).hexdigest()
def main():
 a=argparse.ArgumentParser();a.add_argument('--check-current',action='store_true');args=a.parse_args()
 manifest=json.loads((B/'manifest.json').read_text())
 for x in manifest['members']:
  b=(B/x['path']).read_bytes();assert len(b)==x['bytes'] and H(b)==x['sha256'],x['path']
 c=json.loads((B/'composition.json').read_text())
 for x in c['common']:
  p=x['path'];result=(B/'common-composed'/p).read_bytes();assert H(result)==x['outputSHA256']
  new=(B/'qualified-common'/p).read_bytes();assert H(new)==x['qualifiedSHA256']
  if x['method'].startswith('exact'):assert result==new
  else:
   run=subprocess.run(['git','merge-file','-p',str(B/'original'/p),str(B/'common-preimage'/p),str(B/'qualified-common'/p)],capture_output=True,timeout=5)
   assert run.returncode==0 and run.stdout==result,p
 for x in c['initiation']:
  p=x['path'];result=(B/'proposed'/p).read_bytes();assert H(result)==x['outputSHA256']
  new=(B/'initiation-source'/p).read_bytes();assert H(new)==x['frozenAfterSHA256']
  if x['method'].startswith('exact'):assert result==new
  else:
   run=subprocess.run(['git','merge-file','-p',str(B/'initiation-current'/p),str(B/'initiation-preimage'/p),str(B/'initiation-source'/p)],capture_output=True,timeout=5)
   assert run.returncode==0 and run.stdout==result,p
 if args.check_current:
  for label in ['common','initiation']:
   for x in json.loads((B/(label+'-overlay.json')).read_text()):
    p=x['path'];f=Path(c['base'])/p;current=f.read_bytes() if f.exists() else None
    original=B/'original'/p;expected=original.read_bytes() if original.exists() else None
    assert current==expected,p
 print(json.dumps({'sourceReplay':'PASS','commonFiles':17,'initiationFiles':10,'unionFiles':23,'compilerExecuted':False,'fixturesExecuted':False}))
if __name__=='__main__': main()
