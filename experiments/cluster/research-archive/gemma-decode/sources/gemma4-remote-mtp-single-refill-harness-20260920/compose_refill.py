"""Root-only four-file exact composition; --check never touches the workspace."""
import argparse,json
from pathlib import Path
import prepare as p

def main():
 a=argparse.ArgumentParser(allow_abbrev=False);g=a.add_mutually_exclusive_group(required=True);g.add_argument('--check',action='store_true');g.add_argument('--apply',action='store_true');args=a.parse_args()
 spec,_,_,_,_,union,expected=p.verify();base=json.loads(p.pinned(union['baseSources']))
 if args.check:
  print(json.dumps(dict(status='source-checked',changedFiles=4,nativeSources=123,workspaceMutated=False)));return
 workspace=Path(base['workspace']);assert workspace.resolve()==workspace
 output=Path(spec['plannedSources']);assert not output.exists() and not output.parent.exists() and output.parent.parent.resolve()==output.parent.parent
 for row in base['files']:p.pinned(dict(row,path=str(workspace/row['path'])))
 for row in union['files']:
  target=workspace/row['target'];assert target.parent.resolve()==target.parent
  if row['before'] is None:assert not target.exists() and not target.is_symlink()
  p.pinned(row['source'])
 output.parent.mkdir(mode=0o700)
 for row in union['files']:
  target=workspace/row['target'];after=p.pinned(row['source'])
  if row['before'] is not None:
   before=p.pinned(dict(row['before'],path=str(target)))
   (output.parent/(target.name+'.before')).write_bytes(before)
  with (output.parent/(target.name+'.after')).open('xb') as f:f.write(after)
  if row['before'] is None:
   with target.open('xb') as f:f.write(after)
  else:target.write_bytes(after)
 for row in expected:p.pinned(dict(row,path=str(workspace/row['path'])))
 receipt=dict(base,files=expected,workspaceMutated=True,compilerExecuted=False,**p.source_fields(spec,union))
 with output.open('xb') as f:f.write(p.encode(receipt))
 print(json.dumps(p.pin(output)))
if __name__=='__main__':main()
