"""Install a fresh byte-bound lab bundle. Does not launch inference."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
from parent_settings import SSH

ROOT=Path(__file__).resolve().parent
REMOTE='/Users/developer/DarkbloomDev/gemma4-full-model-ep-20260920-v1'
PRODUCT='GemmaExpertFullCorrectness'
SOURCES=Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-jaccl-startup-progress-draft-20260917/bound/sources.json')

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

INSTALL=r'''
import hashlib,json,os,pathlib,stat,sys,tarfile
root=pathlib.Path(sys.argv[1]);wanted=sys.argv[2]
assert root==pathlib.Path('/Users/developer/DarkbloomDev/gemma4-full-model-ep-20260920-v1')
assert not root.exists() and root.parent.resolve()==root.parent
fs=os.statvfs(root.parent);assert fs.f_bavail*fs.f_frsize>7*1024**3
os.umask(0o077);root.mkdir(mode=0o700)
total=0;seen=set()
with tarfile.open(fileobj=sys.stdin.buffer,mode='r|') as archive:
 for item in archive:
  rel=pathlib.Path(item.name)
  assert item.isfile() and not rel.is_absolute() and '..' not in rel.parts and item.name not in seen
  assert 0<=item.size<=200_000_000
  seen.add(item.name);total+=item.size;assert total<400_000_000
  path=root/rel;path.parent.mkdir(parents=True,exist_ok=True)
  with path.open('xb') as target:
   source=archive.extractfile(item)
   while True:
    block=source.read(1024*1024)
    if not block:break
    target.write(block)
  path.chmod(0o700 if item.name=='bundle/GemmaExpertFullCorrectness' else 0o600)
assert hashlib.sha256((root/'package.json').read_bytes()).hexdigest()==wanted
sys.path.insert(0,str(root))
from benchmark_package import verify
package=verify(wanted)
print(json.dumps(dict(status='installed',root=str(root),packageSHA256=wanted,files=len(package['files']),bytes=total)))
'''

def prepare(binary):
    from build_binding import verify
    binding=verify()
    assert binary==Path(binding['binaryDirectory'])/PRODUCT
    assert binary.stat().st_size==binding['nativeBytes'] and digest(binary)==binding['nativeSHA256']
    source_reference=binding['metadataAndPromptSources']
    assert digest(Path(source_reference['path']))==source_reference['sha256']
    stage=ROOT/'deployment';stage.mkdir(mode=0o700)
    for source in (ROOT/'package').rglob('*'):
        if source.is_file() and '__pycache__' not in source.parts:
            dest=stage/source.relative_to(ROOT/'package');dest.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(source,dest)
    sources=json.loads(Path(source_reference['path']).read_bytes())
    for name,row in sources.items():
        if not (name.startswith('metadata/') or name in ('matrix.json','prompt.ids.json','provenance/prompt-receipt.json')):continue
        src=Path(row['path']);assert digest(src)==row['sha256']
        dest=stage/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dest)
    shutil.copyfile(ROOT/'artifact-bindings.json',stage/'artifact-bindings.json')
    (stage/'bundle').mkdir()
    for name in [PRODUCT,'mlx.metallib','mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal']:
        src=binary.parent/name;dest=stage/'bundle'/name;dest.parent.mkdir(parents=True,exist_ok=True)
        if name!=PRODUCT:
            row=next(r for r in binding['resources'] if r['path']=='bundle/'+name)
            assert src.stat().st_size==row['bytes'] and digest(src)==row['sha256']
        subprocess.run(['/bin/cp','-c',str(src),str(dest)],check=True)
    rows=[]
    for path in sorted(stage.rglob('*')):
        if path.is_file():
            path.chmod(0o700 if path.name==PRODUCT else 0o600)
            rows.append(dict(path=str(path.relative_to(stage)),bytes=path.stat().st_size,sha256=digest(path)))
    package={'schema':'gemma4_full_expert_install_v1','files':rows}
    (stage/'package.json').write_text(json.dumps(package,sort_keys=True,separators=(',',':'))+'\n')
    archive=ROOT/'deployment.tar'
    with tarfile.open(archive,'x') as tar:
        for path in sorted(stage.rglob('*')):
            if path.is_file():tar.add(path,arcname=str(path.relative_to(stage)),recursive=False)
    print(json.dumps({'prepared':str(stage),'packageSHA256':digest(stage/'package.json'),
                      'archiveBytes':archive.stat().st_size,'nativeSHA256':digest(binary)}))

def main():
    import shlex
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('action',choices=['prepare','install'])
    parser.add_argument('--binary',type=Path)
    parser.add_argument('--host',choices=['darkbloom-24','darkbloom-48'])
    args=parser.parse_args()
    if args.action=='prepare':
        assert args.binary and args.binary.is_file();prepare(args.binary);return
    assert args.host
    wanted=digest(ROOT/'deployment/package.json')
    command=shlex.join(['/usr/bin/python3','-c',INSTALL,REMOTE,wanted])
    with (ROOT/'deployment.tar').open('rb') as stream:
        result=subprocess.run(SSH+[args.host,command],stdin=stream,capture_output=True,timeout=120)
    out=ROOT/('installation-'+args.host+'-'+wanted[:12]+'.json')
    record={'exitCode':result.returncode,'stdout':result.stdout.decode(),'stderr':result.stderr.decode(),
            'packageSHA256':wanted}
    with out.open('x') as f:json.dump(record,f,indent=2)
    assert result.returncode==0 and not result.stderr,record
    print(result.stdout.decode())

if __name__=='__main__':main()
