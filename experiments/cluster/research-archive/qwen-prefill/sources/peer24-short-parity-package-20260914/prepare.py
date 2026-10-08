"""Private source-pinned transfer package; no remote or native execution."""
from pathlib import Path
import argparse,datetime,hashlib,importlib.util,json,os,sys,tarfile,uuid
sys.dont_write_bytecode=True
r=Path('/Users/developer/DarkbloomDev/d-inference');research=r.parent/'cluster-research';out=Path(__file__).parent

def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()

p=argparse.ArgumentParser(allow_abbrev=False)
p.add_argument('--native-sha256',required=True);p.add_argument('--public-scan',type=Path,required=True);p.add_argument('--public-scan-sha256',required=True)
a=p.parse_args()
assert sha(a.public_scan)==a.public_scan_sha256
scan=json.loads(a.public_scan.read_bytes());assert scan['passed'] and scan['nativeExecutionPerformed'] is False
release=r/'experiments/cluster/inference/.build/release';assert sha(release/'cluster-inference')==a.native_sha256
previous=research/'peer24-short-reference-package-20260914/manifest.json';assert sha(previous)=='dd2e6d21c1b98e8a90db67e118b3c329e03ac724655e17e37222d669dd4b8758'
prior=json.loads(previous.read_bytes());prior_overlay=[dict(path=e['path'][8:],sha256=e['sha256'],size_bytes=e['size_bytes']) for e in prior['files'] if e['path'].startswith('overlay/')]
assert len(prior_overlay)==536
helper=research/'selected-stage-load-parent-v2-draft/prefill_compute_archive.py';assert sha(helper)=='dde031892fcec8c98b70f4b300e1ef1aaca309547c400b1a50d85e791e069930'
spec=importlib.util.spec_from_file_location('_root_short_parity_archive',helper);archive=importlib.util.module_from_spec(spec);sys.modules[spec.name]=archive;spec.loader.exec_module(archive)
source=archive.archive_sources(r/'experiments/cluster/runtime',out);modules=archive.load_archived_runtime(out,uuid.uuid4().hex)
bundle_sha=modules['bundle'].snapshot(release,out/'bundle');archive.verify_archive(modules,out,source,bundle_sha,[])
files=[];members=[]
for e in scan['files']:
 path=r/e['path'];assert path.is_file() and not path.is_symlink() and sha(path)==e['sha256'] and path.stat().st_size==e['sizeBytes']
 files.append(dict(path='overlay/'+e['path'],size_bytes=e['sizeBytes'],sha256=e['sha256'],mode=0o600));members.append(path)
for path in sorted((out/'bundle').rglob('*')):
 if not path.is_file():continue
 assert not path.is_symlink();files.append(dict(path='bundle/'+path.relative_to(out/'bundle').as_posix(),size_bytes=path.stat().st_size,sha256=sha(path),mode=path.stat().st_mode&0o777));members.append(path)
assert len({e['path'] for e in files})==len(files) and sum(e['size_bytes'] for e in files)<300*1024**2
with tarfile.open(out/'package.tar','x') as tar:
 for e,path in zip(files,members):
  info=tarfile.TarInfo(e['path']);info.size=e['size_bytes'];info.mode=e['mode'];info.mtime=0
  with path.open('rb') as stream:tar.addfile(info,stream)
  assert sha(path)==e['sha256']
m=dict(kind='peer24_short_parity_source_bundle_transfer',createdAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),repository_head=source['dependencies']['repository_head'],files=files,prior_overlay=prior_overlay,native_sha256=a.native_sha256,bundle_manifest_sha256=bundle_sha,source_manifest_sha256=sha(out/'source-manifest.json'),package_sha256=sha(out/'package.tar'),package_bytes=(out/'package.tar').stat().st_size,public_scan_sha256=a.public_scan_sha256)
manifest=out/'manifest.json';manifest.write_text(json.dumps(m,indent=2)+'\n');manifest.chmod(0o600)
original=(research/'peer24-short-reference-package-20260914/install.py').read_text()
assert sha(research/'peer24-short-reference-package-20260914/install.py')=='d77560a552ce78648ac1d72f46a013d2f5099dfbe41b6b7a2fe671a8b1615223'
installer=original.replace('peer24-short-reference-package-20260914','peer24-short-parity-package-20260914').replace('dd2e6d21c1b98e8a90db67e118b3c329e03ac724655e17e37222d669dd4b8758',sha(manifest))
(out/'install.py').write_text(installer);(out/'install.py').chmod(0o600)
print(json.dumps(dict(manifestSHA256=sha(manifest),nativeSHA256=a.native_sha256,bundleSHA256=bundle_sha,sourceFiles=len(source['files']),overlayFiles=len(scan['files']),priorOverlayFiles=len(prior_overlay),packageBytes=m['package_bytes'],packageSHA256=m['package_sha256'],installerSHA256=sha(out/'install.py'))))
