"""Root-granted create-only small launcher derivative; no process/network/model operations."""
from pathlib import Path
import argparse,difflib,hashlib,json,os
from prepare_inputs import canonical,REFERENCE_REMOTE,REFERENCE_RUN,REQUEST,PROMPT,expected_packet
BASE=Path(__file__).resolve().parent
ROOT=BASE.parent.parent
OLD=ROOT/'qwen27b-8k-full-reference-20260915'
OLD_LAUNCH='/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/supervisor-27b-8k-owned'
OLD_RUN='/Users/developer/DarkbloomDev/qwen-registered-generation-reference-20260915/runs/long-27b-cut16-1'

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,data):
    p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    with p.open('xb') as f:f.write(data)
def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--inputs',type=Path,required=True);a=p.parse_args()
    for row in json.loads((BASE/'input-pins.json').read_bytes()):
        source=Path(row['path'])
        if source.stat().st_size!=row['bytes'] or sha(source)!=row['sha256']:raise ValueError('Pinned reference preparation input changed')
    job=json.loads((a.inputs/'reference-job.json').read_bytes());prompt=(a.inputs/'prompt.ids.json').read_bytes()
    if job!=expected_packet()[0] or hashlib.sha256(prompt).hexdigest()!=PROMPT:
        raise ValueError('Wrong fresh C256 reference packet')
    out=BASE/'reference';out.mkdir(mode=0o700)
    files=json.loads((OLD/'package/manifest.json').read_bytes())['files']
    if len(files)!=64 or sum(x['bytes'] for x in files)>4*1024**2:raise ValueError('Unexpected bounded launcher closure')
    copied=[]
    for row in files:
        rel=Path(row['path']);source=OLD/'package'/rel
        if rel.is_absolute() or '..' in rel.parts or source.is_symlink() or source.stat().st_size!=row['bytes'] or sha(source)!=row['sha256']:
            raise ValueError('Reference launcher source changed')
        data=source.read_bytes()
        if row['path']=='example-job.json':data=canonical(job)
        elif row['path']=='prompt.ids.json':data=prompt
        elif row['path'] in ['HANDOFF.md','README.md']:
            data=b'Private C256 reference derivative. Same d717 native and 21 Python runtime/test sources. New request, chunk and run paths only. Root-owned execution; no result exists at preparation. Copied historical receipts are not new validation.\n'
        save(out/'package'/rel,data);copied.append(dict(path=row['path'],bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
    save(out/'package/manifest.json',canonical(dict(schema=json.loads((OLD/'package/manifest.json').read_bytes())['schema'],files=copied)))
    manifest_sha=sha(out/'package/manifest.json');job_sha=sha(out/'package/example-job.json')
    old_manifest=sha(OLD/'package/manifest.json');old_job=sha(OLD/'package/example-job.json')
    runner=(OLD/'run_physical.py').read_text()
    runner=runner.replace("BASE.parent / 'qwen27b-owner-load-operands-rerun-20260915'", "Path("+repr(str(ROOT))+ ") / 'qwen27b-owner-load-operands-rerun-20260915'")
    runner=runner.replace("root/'supervisor-27b-8k-owned'","Path("+repr(REFERENCE_REMOTE)+")").replace(OLD_RUN,REFERENCE_RUN)
    runner=runner.replace(old_manifest,manifest_sha).replace(old_job,job_sha)
    installer=(OLD/'install_new_tree.py').read_text().replace(OLD_LAUNCH,REFERENCE_REMOTE)
    save(out/'run_physical.py',runner.encode());save(out/'install_new_tree.py',installer.encode())
    save(out/'owned_process.py',(OLD/'owned_process.py').read_bytes())
    deployment=dict(schema='cut16_reference_copy_only_tree_v1',files={})
    for source in sorted((out/'package').rglob('*')):
        if source.is_file():deployment['files']['owner/'+str(source.relative_to(out/'package'))]=dict(source=str(source),bytes=source.stat().st_size,sha256=sha(source),mode=0o600)
    if len(deployment['files'])!=65:raise ValueError('Unexpected deployment closure')
    save(out/'deployment.json',canonical(deployment))
    patch=''.join(difflib.unified_diff((OLD/'run_physical.py').read_text().splitlines(True),runner.splitlines(True),fromfile='old/run_physical.py',tofile='new/run_physical.py'))
    patch+=''.join(difflib.unified_diff((OLD/'install_new_tree.py').read_text().splitlines(True),installer.splitlines(True),fromfile='old/install_new_tree.py',tofile='new/install_new_tree.py'))
    save(out/'binding.patch',patch.encode())
    save(out/'lineage.json',canonical(dict(priorPackageSHA256=old_manifest,packageSHA256=manifest_sha,jobSHA256=job_sha,
        nativeSHA256=job['native_sha256'],promptSHA256=PROMPT,ordinaryReferenceRequired=True,noNativeOrRemoteExecution=True)))
    members={str(x.relative_to(out)):dict(bytes=x.stat().st_size,sha256=sha(x)) for x in sorted(out.rglob('*')) if x.is_file()}
    save(out/'manifest.json',canonical(dict(files=members,schema='private_c256_reference_preparation_v1')))
    print(json.dumps(dict(output=str(out),manifestSHA256=sha(out/'manifest.json'),jobSHA256=job_sha)))
if __name__=='__main__':os.umask(0o077);main()
