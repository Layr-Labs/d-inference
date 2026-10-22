#!/usr/bin/env python3
"""Pins, exact source inverses and scalar evidence arithmetic; no native/child."""
import ast,hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def sha(raw):return hashlib.sha256(raw).hexdigest()
def read(row,base=None):
 p=Path(row['path']);p=base/p if base is not None else p
 assert p.is_file() and not p.is_symlink() and p.stat().st_size<2*1024**2
 raw=p.read_bytes();assert len(raw)==row['bytes'] and sha(raw)==row['sha256'],p
 return raw

def main():
 own=json.loads((ROOT/'source-inputs.json').read_bytes())
 for row in own['members']:read(row,ROOT)
 for row in own['context']:read(row)
 spec=json.loads((ROOT/'integration.json').read_bytes());base=json.loads(read(spec['baseSources']))
 current={x['path']:x for x in base['files']};assert len(current)==122
 transforms=json.loads((ROOT/'transforms.json').read_bytes())
 for row in spec['files']:
  assert current.get(row['target'])==row['before']
  raw=read(row['source']);name=Path(row['target']).name
  if row['before'] is not None:
   old=(ROOT/'preimages'/name).read_text();new=raw.decode();value=old
   for h in transforms[name]:assert value.count(h['before'])==1;value=value.replace(h['before'],h['after'],1)
   assert value==new
   for h in reversed(transforms[name]):assert value.count(h['after'])==1;value=value.replace(h['after'],h['before'],1)
   assert value==old
  current[row['target']]=dict(path=row['target'],bytes=len(raw),sha256=sha(raw))
 assert [current[k] for k in sorted(current)]==json.loads((ROOT/'expected-sources.json').read_bytes())['files']
 target=(ROOT/'Runtime/Gemma4MTPPullTarget.swift').read_text();before=(ROOT/'preimages/Gemma4MTPPullTarget.swift').read_text()
 assert target.count('if ledger.proposalCredit > 0 { try grant(min(2,ledger.proposalCredit),check:checked) }')==1
 assert target[target.index('    func verify('):]==before[before.index('    func verify('):]
 assert (ROOT/'Tests/RefillPolicyChecks.swift').read_text().count('try test("')==11
 evidence=json.loads((ROOT/'phase-evidence.json').read_bytes());terminal=json.loads(read(evidence['terminal']))
 samples=terminal['result']['samples'][1:];assert len(samples)==3
 assert sum(s['decodeNanoseconds'] for s in samples)==evidence['measuredDecodeNanoseconds']
 for field,want in evidence['meanPhaseNanosecondsPerRequest'].items():
  actual=sum(w[field] for s in samples for w in s['phaseTiming']['windows'])/3
  assert actual==want
 ast.parse((ROOT/'check_sources.py').read_text())
 print(json.dumps(dict(sourceOnly=True,members=len(own['members']),contextPins=len(own['context']),overlays=3,addedRuntime=1,expectedSources=123,stagedFoundationGroups=11,nativeExecuted=False,compilerExecuted=False)))
if __name__=='__main__':main()
