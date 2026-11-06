from pathlib import Path
import hashlib,json,shlex,shutil,subprocess,time

root=Path(__file__).resolve().parent
target=root/'resident-physical-cut4-20260915'
review=root/'resident-physical-cut4-review-draft/source-review.json'
review_pin='54914e001dd5096207b152d05c3c85fd36d344c6ed4e1383a381053b24eae8d4'
assert hashlib.sha256(review.read_bytes()).hexdigest()==review_pin
assert json.loads((target/'cpu-cut4.json').read_bytes())['exitCode']==0
shutil.copy2(review,target/'cut4-source-review.json')
prior=json.loads((target/'prior-cut8-manifest.json').read_bytes())
changes=[]
for row in prior['files']:
    actual=hashlib.sha256((target/row['path']).read_bytes()).hexdigest()
    if actual!=row['sha256']:changes.append(row['path'])
assert changes==['README.md','selected_source.py','test_selected_cut.py'],changes
(target/'cut4-source-delta.json').write_text(json.dumps({'changedInheritedMembers':changes,
    'unchangedInheritedMembers':len(prior['files'])-len(changes),'physicalExecutionQualified':False},indent=2)+'\n')
manifest={'schema':'resident_physical_launcher_manifest_v1','scope':'Fixed registered9B cut4/28;31CPU tests;physical execution pending',
    'priorManifestSHA256':hashlib.sha256((target/'prior-cut8-manifest.json').read_bytes()).hexdigest(),
    'sourceReviewSHA256':review_pin,'files':[]}
for p in sorted(target.rglob('*')):
    assert not p.is_symlink()
    if p.is_file():
        assert p.name!='manifest.json' and '__pycache__' not in p.parts
        raw=p.read_bytes();manifest['files'].append({'path':str(p.relative_to(target)),'size_bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()})
assert len(manifest['files'])<=100
with (target/'manifest.json').open('x') as f:json.dump(manifest,f,indent=2,sort_keys=True);f.write('\n')
pin=hashlib.sha256((target/'manifest.json').read_bytes()).hexdigest()
verify='''from pathlib import Path
import hashlib,json,sys
p=Path(sys.argv[1]);pin=sys.argv[2]
assert hashlib.sha256((p/'manifest.json').read_bytes()).hexdigest()==pin
m=json.loads((p/'manifest.json').read_bytes());assert 1<=len(m['files'])<=100
for row in m['files']:
 f=p/row['path'];assert f.is_file() and not f.is_symlink()
 raw=f.read_bytes();assert len(raw)==row['size_bytes'] and hashlib.sha256(raw).hexdigest()==row['sha256']
print(json.dumps({'verifiedMembers':len(m['files']),'manifestSHA256':pin,'destination':str(p)}))
'''
results=[]
for host in ('darkbloom-24','darkbloom-48'):
    start=time.monotonic()
    check=['/usr/bin/python3','-c','import os,sys;assert not os.path.lexists(sys.argv[1])',str(target)]
    subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8',host,shlex.join(check)],check=True,timeout=15)
    subprocess.run(['scp','-q','-r',str(target),host+':'+str(target)],check=True,timeout=45)
    p=subprocess.run(['ssh','-o','BatchMode=yes',host,shlex.join(['/usr/bin/python3','-',str(target),pin])],input=verify,capture_output=True,text=True,check=True,timeout=30)
    assert not p.stderr
    item=json.loads(p.stdout);item.update(host=host,copyAndVerifySeconds=time.monotonic()-start);results.append(item)
    (root/'resident-cut4-launcher-remote-verification-20260915.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(item),flush=True)
