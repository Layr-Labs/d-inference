import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def read(row,base=None):
 p=Path(row['path']);p=base/p if base else p
 assert p.is_file() and not p.is_symlink() and p.stat().st_size<2*1024**2
 raw=p.read_bytes();assert len(raw)==row['bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
 return raw

def main():
 own=json.loads((ROOT/'source-inputs.json').read_bytes())
 for row in own['members']:read(row,ROOT)
 spec=json.loads((ROOT/'integration.json').read_bytes())
 for key in ('originalRefillManifest','descriptionManifest'):
  doc=json.loads(read(spec[key]));base=Path(spec[key]['path']).parent
  for row in doc['members']:read(row,base)
 old=json.loads(read(spec['originalIntegration']));prior=json.loads(read(old['baseSources']))
 description=json.loads(read(spec['descriptionIntegration']));base=json.loads(read(spec['baseSources']))
 current={x['path']:x for x in prior['files']}
 for row in description['files']:
  assert current[row['target']]==row['before'];read(row['source'])
  current[row['target']]=dict(path=row['target'],bytes=row['source']['bytes'],sha256=row['source']['sha256'])
 assert [current[k] for k in sorted(current)]==base['files'] and len(current)==122
 assert spec['files']==old['files']
 for row in spec['files']:
  assert current.get(row['target'])==row['before'];read(row['source'])
  current[row['target']]=dict(path=row['target'],bytes=row['source']['bytes'],sha256=row['source']['sha256'])
 assert [current[k] for k in sorted(current)]==json.loads((ROOT/'expected-sources.json').read_bytes())['files'] and len(current)==123
 print(json.dumps(dict(sourceOnly=True,baseSources=122,projectedSources=123,unchangedRefillSources=4,descriptionPreserved=True,nativeExecuted=False)))
if __name__=='__main__':main()
