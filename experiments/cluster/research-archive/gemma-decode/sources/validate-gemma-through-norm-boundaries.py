"""Bounded native Gemma diagnostic/control matrix; no performance qualification."""
import hashlib,json,os,shutil,signal,subprocess,sys,time
from pathlib import Path
REPO=Path('/Users/developer/DarkbloomDev/d-inference');CLUSTER=REPO/'experiments/cluster'
sys.path.insert(0,str(CLUSTER))
from runtime.configuration import loopback_addresses
OUT=Path(sys.argv[1]);OUT.mkdir(mode=0o700,parents=True,exist_ok=False)
source_bundle=CLUSTER/'inference/.build/arm64-apple-macosx/release'
bundle=OUT/'bundle';bundle.mkdir()
for path in [source_bundle/'cluster-inference',source_bundle/'mlx.metallib',*source_bundle.glob('*.bundle')]:
    if path.is_dir():shutil.copytree(path,bundle/path.name)
    else:shutil.copyfile(path,bundle/path.name)
(bundle/'cluster-inference').chmod(0o700)
files={str(path.relative_to(bundle)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(bundle.rglob('*')) if path.is_file()}
receipt=dict(binary_sha256=files['cluster-inference'],bundle_files=files,
    driver_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),correctness_only=True,runs=[],controls=[])
source=[]
for name in sorted(subprocess.check_output(['rg','--files','experiments/cluster'],cwd=REPO,text=True).splitlines()):
    path=REPO/name;target=OUT/'source'/path.relative_to(CLUSTER)
    target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,target)
    source.append(dict(path=name,sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
manifest=OUT/'source-manifest.json';manifest.write_text(json.dumps(source,indent=2)+'\n')
receipt['source_manifest_sha256']=hashlib.sha256(manifest.read_bytes()).hexdigest()
shutil.copyfile(Path(__file__),OUT/Path(__file__).name)
teacher=OUT/'teacher.json';teacher.write_text(json.dumps([12,25,38,51,64,77,90]))
def save(): (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
def run(profile,dtype,seed,variant,tp):
    name=f'{profile}-{dtype}-seed{seed}-{variant}-'+('ffn' if tp else 'solo')
    directory=OUT/name;directory.mkdir()
    hosts=directory/'hosts.json';hosts.write_text(json.dumps(loopback_addresses()))
    processes=[];handles=[];deadline=time.monotonic()+80
    try:
        for rank in range(2 if tp else 1):
            args=[str(bundle/'cluster-inference'),'--mode','ffn-tp' if tp else 'baseline',
                '--synthetic','--synthetic-profile',profile,'--synthetic-dtype',dtype,
                '--seed',str(seed),'--partition','ffn','--ffn-branch-precision','float32-through-norm',
                '--prompt-tokens','65' if seed==7 else '97','--chunk-size','32' if seed==7 else '16',
                '--decode-tokens','8','--teacher-tokens-file',str(teacher),
                '--repeats','1','--warmups','0','--timeout-seconds','70',
                '--logits-file',str(directory/f'rank-{rank}.logits.json')]
            if variant!='ordinary':args+=['--gemma-diagnostic']
            if variant=='capture':args+=['--gemma-boundary-file',str(directory/f'rank-{rank}.trace.json')]
            env={k:v for k,v in os.environ.items() if not k.startswith(('MLX_','JACCL_','DARKBLOOM_'))}
            if tp:
                args+=['--transport','loopback-test'];env.update(MLX_RANK=str(rank),MLX_HOSTFILE=str(hosts))
            out=(directory/f'rank-{rank}.stdout').open('w');err=(directory/f'rank-{rank}.stderr').open('w');handles += [out,err]
            processes.append(subprocess.Popen(args,stdout=out,stderr=err,env=env,start_new_session=True))
        codes=[p.wait(timeout=max(1,deadline-time.monotonic())) for p in processes]
    finally:
        for p in processes:
            if p.poll() is None:os.killpg(p.pid,signal.SIGKILL);p.wait()
        for handle in handles:handle.close()
    receipt['runs'].append(dict(name=name,exit_codes=codes));save()
    assert all(code==0 for code in codes),name
    reports=[json.loads((directory/f'rank-{i}.stdout').read_text()) for i in range(len(processes))]
    logits=[json.loads((directory/f'rank-{i}.logits.json').read_text()) for i in range(len(processes))]
    assert all(x==logits[0] for x in logits)
    for r in reports:
        assert r['schemaVersion']==7 and r['ffnBranchPrecision']=='float32-through-norm'
        assert r['runs'][0]['decodeInputTokens']==[12,25,38,51,64,77,90]
        if variant!='ordinary':assert r['gemmaDiagnosticScheduleEnabled'] and r['correctnessOnly'] and not r['throughputMeasurementValid']
        if variant=='capture':assert r['gemmaBoundaryTraceEnabled']
    return name,logits[0]
old=OUT.parent/'gemma-through-norm-20260913'
for profile,dtype,seed in [('gemma-moe','bfloat16',7),('gemma-moe-w8','bfloat16',101)]:
    for tp in (False,True):
        variants={}
        for variant in ('ordinary','diagnostic','capture'):
            name,values=run(profile,dtype,seed,variant,tp);variants[variant]=values
            print(name,'passed',flush=True)
        previous=json.loads((old/(f'{profile}-{dtype}-seed{seed}-float32-through-norm-'+('ffn' if tp else 'solo'))/'rank-0/logits.json').read_text())
        # Capture equality is a gate; ordinary scheduling equivalence is measured separately.
        assert variants['capture']==variants['diagnostic'],'Capture changed diagnostic logits'
        assert variants['ordinary']==previous,'Ordinary execution changed from archived current-policy result'
        record=dict(profile=profile,dtype=dtype,seed=seed,tp=tp,capture_exact=True,
            ordinary_archived_exact=True,diagnostic_matches_ordinary=variants['diagnostic']==variants['ordinary'])
        receipt['controls'].append(record);save()
        print('controls',record,flush=True)
print('Evidence:',OUT/'receipt.json',flush=True)
