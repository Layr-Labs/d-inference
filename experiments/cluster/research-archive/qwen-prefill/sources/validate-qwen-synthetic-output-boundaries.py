"""Bounded same-hidden final norm/head diagnostics, with immutable local receipts."""
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
REPO=Path('/Users/developer/DarkbloomDev/d-inference');CLUSTER=REPO/'experiments/cluster'
OUT=Path(sys.argv[1]);OUT.mkdir(mode=0o700,parents=True,exist_ok=False)
SOURCE=CLUSTER/'inference/.build/arm64-apple-macosx/release';BUNDLE=OUT/'bundle';BUNDLE.mkdir()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for p in [SOURCE/'cluster-inference',SOURCE/'mlx.metallib',*SOURCE.glob('*.bundle')]:
 if p.is_dir():shutil.copytree(p,BUNDLE/p.name)
 else:shutil.copy2(p,BUNDLE/p.name)
manifest=[]
for name in sorted(subprocess.check_output(['rg','--files','experiments/cluster'],cwd=REPO,text=True).splitlines()):
 p=REPO/name;target=OUT/'source'/p.relative_to(CLUSTER);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
 manifest.append(dict(path=name,sha256=sha(p)))
p=OUT/'source-manifest.json';p.write_text(json.dumps(manifest,indent=2)+'\n')
r=dict(synthetic_only=True,performance_qualification=False,driver_sha256=sha(Path(__file__)),source_manifest_sha256=sha(p),bundle_files={str(p.relative_to(BUNDLE)):sha(p) for p in sorted(BUNDLE.rglob('*')) if p.is_file()},executions=[],status='running')
shutil.copy2(Path(__file__),OUT/Path(__file__).name)
def save():(OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
env={k:v for k,v in os.environ.items() if not k.startswith(('MLX_','JACCL_','DARKBLOOM_'))}
env['DARKBLOOM_BF16_WEIGHTS']='1'
try:
 for profile in ['tiny','qwen27-heads']:
  for dtype in ['float32','bfloat16']:
   for prompt,seed in [(65,7),(66,7),(96,31)]:
    name=f'{profile}-{dtype}-{prompt}-seed{seed}';command=[str(BUNDLE/'cluster-inference'),'--mode','qwen-output-check','--synthetic','--synthetic-profile',profile,'--synthetic-dtype',dtype,'--prompt-tokens',str(prompt),'--chunk-size','32','--decode-tokens','1','--repeats','1','--warmups','0','--seed',str(seed),'--timeout-seconds','45']
    with (OUT/(name+'.json')).open('w') as out,(OUT/(name+'.stderr')).open('w') as err:
     result=subprocess.run(command,cwd=BUNDLE,env=env,stdout=out,stderr=err,timeout=50)
    assert result.returncode==0,name
    record=json.loads((OUT/(name+'.json')).read_text());assert record['kind']=='qwen_output_narrowing_check' and record['diagnosticOnly'] and not record['throughputValid']
    assert record['originalVersusRecomputedFull']['exactValues'], 'Original and replayed full output differ'
    r['executions'].append(dict(name=name,command=command,result_sha256=sha(OUT/(name+'.json')),exit_code=0,record=record));save()
    print(name,'norm exact',record['normFullVersusSliced']['exactValues'],'head RMS',record['headFullVersusSingleRow']['relativeRMSError'],'narrowed argmax',record['sliceBeforeNormAndHead']['argmaxToken'],flush=True)
 r['status']='passed'
except BaseException as e:
 r.update(status='failed',error=str(e));raise
finally:save()
print('Evidence:',OUT/'receipt.json',flush=True)
