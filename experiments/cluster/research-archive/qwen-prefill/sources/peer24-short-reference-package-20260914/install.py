from pathlib import Path, PurePosixPath
import json,hashlib,tarfile,os,shutil,subprocess
root=Path('/Users/developer/DarkbloomDev/cluster-research/peer24-short-reference-package-20260914')
repo=Path('/Users/developer/DarkbloomDev/d-inference')
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for x in iter(lambda:f.read(1024**2),b''):h.update(x)
 return h.hexdigest()
assert digest(root/'manifest.json')=='dd2e6d21c1b98e8a90db67e118b3c329e03ac724655e17e37222d669dd4b8758'
m=json.loads((root/'manifest.json').read_text());assert digest(root/'package.tar')==m['package_sha256']
head=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip();assert head==m['repository_head']
assert not subprocess.check_output(['git','-C',str(repo),'submodule','foreach','--recursive','--quiet','git status --porcelain --untracked-files=no'],text=True).strip()
old={e['path']:e for e in m['prior_overlay']}
for n,e in old.items():assert (repo/n).is_file() and not (repo/n).is_symlink() and digest(repo/n)==e['sha256'],n
for e in m['files']:
 if e['path'].startswith('overlay/'):
  n=e['path'][8:];p=repo/n
  assert n in old or not p.exists() or (p.is_file() and not p.is_symlink() and digest(p)==e['sha256']),n
unpacked=root/'unpacked';assert not unpacked.exists();unpacked.mkdir(mode=0o700)
expected={e['path']:e for e in m['files']};assert len(expected)==len(m['files']) and sum(e['size_bytes'] for e in m['files'])<300*1024**2
seen=set()
with tarfile.open(root/'package.tar','r') as t:
 for item in t:
  n=item.name;pure=PurePosixPath(n)
  assert item.isfile() and n in expected and n not in seen and not pure.is_absolute() and '..' not in pure.parts
  e=expected[n];assert item.size==e['size_bytes'] and item.mode==e['mode']
  dest=unpacked/n;dest.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
  with t.extractfile(item) as src,dest.open('xb') as dst:shutil.copyfileobj(src,dst,1024**2)
  dest.chmod(e['mode']);assert digest(dest)==e['sha256'];seen.add(n)
assert seen==set(expected)
changed=[]
for e in m['files']:
 if not e['path'].startswith('overlay/'):continue
 n=e['path'][8:];dest=repo/n
 for parent in dest.parents:
  if parent==repo:break
  assert not parent.is_symlink()
 if dest.exists() and digest(dest)==e['sha256']:continue
 mode=dest.stat().st_mode & 0o777 if dest.exists() else 0o600
 if dest.exists():
  assert n in old and digest(dest)==old[n]['sha256'];backup=root/'previous-source'/n;backup.parent.mkdir(mode=0o700,parents=True,exist_ok=True);shutil.copyfile(dest,backup);backup.chmod(0o600)
 dest.parent.mkdir(parents=True,exist_ok=True);temp=dest.with_name(dest.name+'.cluster-update-20260914');assert not temp.exists()
 shutil.copyfile(unpacked/e['path'],temp);temp.chmod(mode);assert digest(temp)==e['sha256'];os.replace(temp,dest);changed.append(n)
for e in m['files']:
 if e['path'].startswith('overlay/'):assert digest(repo/e['path'][8:])==e['sha256']
assert digest(unpacked/'bundle/cluster-inference')==m['native_sha256']
result={'kind':'peer24_source_and_bundle_install','passed':True,'repository_head':head,'overlay_files':sum(e['path'].startswith('overlay/') for e in m['files']),'changed_paths':changed,'bundle_manifest_sha256':m['bundle_manifest_sha256'],'native_sha256':m['native_sha256'],'native_execution':False}
(root/'install-receipt.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
