from pathlib import Path
import hashlib,json,ast
D=Path(__file__).resolve().parent;B=D.parent;R=B.parent
BASES={'local':B/'harness-local-mtp-packed-head-v1','remote':R/'gemma4-mtp-remote-packed-head-physical-20260920','numerical':R/'gemma4-mtp-remote-packed-head-numerical-empty-20260920'}
HASHES={'local':'14a383d476eb6414232b1342a76d7afa1c0c4d9340bdc742a4cc9771dbc2d692','remote':'c64216737603ef19ece4206cbbeee2bdd81414b49632c0203ce218d111b8b7e4','numerical':'287b7c69e3f03b03d6042b7ece23e3f302026daf64efdd47f83895bb26c024ea'}
projects={};original={};ops={}
def sha(b):return hashlib.sha256(b).hexdigest()
for k,p in BASES.items():
 raw=(p/'source-inputs.json').read_bytes();assert sha(raw)==HASHES[k]
 projects[k]={}
 for row in json.loads(raw)['members']:
  b=(p/row['path']).read_bytes();assert(len(b),sha(b))==(row['bytes'],row['sha256'])
  projects[k][row['path']]=b.decode()
 original[k]=dict(projects[k])
DEPTH=R/'gemma4-remote-mtp-depth-harness-delta-20260920'
depth_raw=(DEPTH/'source-inputs.json').read_bytes();assert sha(depth_raw)=='aa9cfbb75d77df1693b4c4d7c8927192ad5a6754f1339a600a7ea36fc31f0e53'
for row in json.loads(depth_raw)['members']:
 b=(DEPTH/row['path']).read_bytes();assert(len(b),sha(b))==(row['bytes'],row['sha256'])
for row in json.loads((DEPTH/'composition.json').read_bytes())['files']:
 name=row['path'];before=projects['remote'][name].encode();assert(len(before),sha(before))==(row['before']['bytes'],row['before']['sha256'])
 after=(DEPTH/row['source']).read_bytes();assert(len(after),sha(after))==(row['after']['bytes'],row['after']['sha256'])
 projects['remote'][name]=after.decode()
CONTROL=R/'gemma4-remote-control-harness-delta-20260920'
control_raw=(CONTROL/'source-inputs.json').read_bytes();assert sha(control_raw)=='69f69edb645b3367e2550fa5201250719d7e194bbd64597840503127c8778a81'
for row in json.loads(control_raw)['members']:
 b=(CONTROL/row['path']).read_bytes();assert(len(b),sha(b))==(row['bytes'],row['sha256'])
for row in json.loads((CONTROL/'composition.json').read_bytes())['files']:
 name=row['path']
 if row['before'] is None:assert name not in projects['remote']
 else:
  before=projects['remote'][name].encode();assert(len(before),sha(before))==(row['before']['bytes'],row['before']['sha256'])
 after=(CONTROL/row['source']).read_bytes();assert(len(after),sha(after))==(row['after']['bytes'],row['after']['sha256'])
 projects['remote'][name]=after.decode()
projects['numerical']['control_contract.py']=projects['remote']['package/control_contract.py']
projects['numerical']['binding_common.py']=projects['remote']['package/binding_common.py']
def edit(k,n,a,b,count=1):
 s=projects[k][n];assert s.count(a)==count,(k,n,a,s.count(a));projects[k][n]=s.replace(a,b);ops.setdefault((k,n),[]).append(dict(before=a,after=b,count=count))
for k in ['local','remote']:
 old='gemma4-local-mtp-packed-head-20260920-v1' if k=='local' else 'gemma4-remote-mtp-packed-head-20260920-v1'
 new='gemma4-local-mtp-o128-20260920-v1' if k=='local' else 'gemma4-remote-mtp-o128-20260920-v1'
 for n,s in list(projects[k].items()):
  if n.endswith('.py') and old in s:edit(k,n,old,new,s.count(old))
workload='''"""Closed full-model cohort counts; no resource or execution authority."""
def require(condition, message):
    if not condition: raise ValueError(message)

def counts(job):
    require(type(job) is dict and job.get('schema')=='gemma4_resident_benchmark_v1'
        and job.get('mode')=='full' and type(job.get('promptCount')) is int and job['promptCount'] in (128,4096)
        and type(job.get('outputCount')) is int and job['outputCount'] in (16,128)
        and type(job.get('chunkSize')) is int and job['chunkSize']==64
        and type(job.get('cut')) is int and job['cut']==7
        and job.get('residualDType')=='bfloat16' and job.get('prefillPolicy')=='serial'
        and type(job.get('timeoutSeconds')) is int and job['timeoutSeconds']==300,
        'Closed full P128/P4096 C64 O16/O128 cut7 BF16 workload')
    p,o=job['promptCount'],job['outputCount']
    return dict(prompt=p,output=o,decode=o-1,frontier=p+o-1,maximumTokens=p+o,
        measuredDecodeTokens=3*(o-1),allGeneratedTokens=4*o,frames=(p+63)//64+o-1)

def state_geometry(layer,component,frontier):
    require(type(frontier) is int and 1<=frontier<=4223,'Closed final frontier')
    if component=='kv.position_offsets':return 'int32',[1],4,[]
    require(component in ('kv.keys','kv.values'),'Canonical attention component')
    dtype=layer['dtype'];require(dtype in ('float16','bfloat16','float32'),'Observed cache dtype')
    start=max(0,frontier-layer['window']) if layer['window'] else 0
    shape=[1,layer['kvHeads'],frontier-start,layer['headDimension']]
    count=shape[1]*shape[2]*shape[3]*(4 if dtype=='float32' else 2)
    return dtype,shape,count,[start,frontier]

def target_extra_logical_bytes(job):
    f=counts(job)['frontier']
    # Exact34-term identity sum: two width4 outputs, four1MiB headrows,
    # one snapshot, separately named sender packs, hidden and16KiB control.
    return 40053794+8192*f+16384*min(f,1024)
'''
for k in ['local','remote']:
 projects[k]['package/workload_contract.py']=workload
projects['local']['workload_contract.py']=workload
projects['numerical']['workload_contract.py']=workload
# Explicit case output selection; default16 preserves existing caller behavior.
for k in ['local','remote']:
 edit(k,'root_run.py',"    p.add_argument('--depth'" if k=='local' else "    p.add_argument('--prompt'", "    p.add_argument('--output-count',type=int,choices=[16,128],default=16)\n"+("    p.add_argument('--depth'" if k=='local' else "    p.add_argument('--prompt'"))
 if k=='local':
  edit(k,'root_run.py',"'--depth',str(args.depth),'--native-operation'","'--depth',str(args.depth),'--output-count',str(args.output_count),'--native-operation'")
 else:edit(k,'root_run.py',"'--prompt',str(a.prompt),'--depth',str(a.depth),'--embedding-sha256'","'--prompt',str(a.prompt),'--output-count',str(a.output_count),'--depth',str(a.depth),'--embedding-sha256'")
edit('local','run_case.py','def prepare(name,count,cut,capture,chunk,policy,match,depth,operation):','def prepare(name,count,cut,capture,chunk,policy,match,depth,operation,output_count=16):')
edit('local','run_case.py','    assert count in (128,4096) and (cut,chunk,policy,match)',"    assert type(output_count) is int and output_count in (16,128)\n    assert count in (128,4096) and (cut,chunk,policy,match)")
edit('local','run_case.py','outputCount=16,timeoutSeconds=300','outputCount=output_count,timeoutSeconds=300')
edit('local','run_case.py',"    p.add_argument('--depth'","    p.add_argument('--output-count',type=int,choices=[16,128],default=16)\n    p.add_argument('--depth'")
edit('local','run_case.py','a.match,a.depth,a.native_operation);','a.match,a.depth,a.native_operation,a.output_count);')
edit('remote','jobs.py','def prepare(name,count,capture,embedding,depth=2):','def prepare(name,count,capture,embedding,depth=2,output_count=16):')
edit('remote','jobs.py','    assert count in [128,4096]',"    assert type(output_count) is int and output_count in (16,128)\n    assert count in [128,4096]")
edit('remote','jobs.py','chunkSize=64,outputCount=16,','chunkSize=64,outputCount=output_count,')
edit('remote','jobs.py','promptCount=count,depth=depth,capture=capture','promptCount=count,outputCount=output_count,depth=depth,capture=capture')
edit('remote','prepare_case.py',"p.add_argument('--prompt'","p.add_argument('--output-count',type=int,choices=[16,128],default=16);p.add_argument('--prompt'")
edit('remote','prepare_case.py','a.prompt,a.capture,a.embedding_sha256,a.depth)','a.prompt,a.capture,a.embedding_sha256,a.depth,a.output_count)')
# Original result checks remain; only closed dynamic counts replace O16 constants.
for name in ['package/solo_contract.py','package/local_mtp_base_contract.py']:
 edit('local',name,'from binding_common import require','from binding_common import require\nfrom workload_contract import counts')
 signature='def validate_result(value, job):' if 'solo' in name else 'def validate_result(value,job,config,config_sha,operation):'
 edit('local',name,signature,signature+"\n    c=counts(job)")
 for old,new in [("len(tokens)==16","len(tokens)==c['output']"),("job['promptCount']+15","c['frontier']"),("('decode',15)","('decode',c['decode'])")]:
  n=projects['local'][name].count(old)
  if n:edit('local',name,old,new,n)
 if 'solo' in name:
  edit('local',name,'len(agreements)==16',"len(agreements)==c['output']")
  edit('local',name,"(job['promptCount']+63)//64+15","c['frames']")
 else:edit('local',name,'len(widths)+sum(accepted)==15',"len(widths)+sum(accepted)==c['decode']")
for name in ['package/run_benchmark.py','compare.py']:
 # Modules already search package path before this import (compare) or live there.
 text=projects['local'][name]
 anchor='from binding_common import ' if name.startswith('package/') else 'from package.binding_common import '
 # Insert next to imports independent of exact existing style.
 edit('local',name,'import argparse','from workload_contract import counts\nimport argparse')
 if name.startswith('package/'):
  old="    require(job['promptCount'] in (128,4096) and (job['chunkSize'],job['outputCount'],job['cut'],job['prefillPolicy'])\n            ==(64,16,7,'serial') and type(job['captureEvidence']) is bool, 'Local target workload')"
  new="    counts(job)\n    require(type(job['captureEvidence']) is bool, 'Local target workload')"
 else:
  old="require(job['promptCount'] in (128,4096) and (job['mode'],job['chunkSize'],job['outputCount'],job['cut'],job['prefillPolicy'])\n        ==('full',64,16,7,'serial') and type(job['captureEvidence']) is bool"
  new="require(counts(job) and type(job['captureEvidence']) is bool"
 edit('local',name,old,new)
 if name=='compare.py':edit('local',name,'decode=45e9/',"decode=counts(job)['measuredDecodeTokens']*1e9/")
edit('remote','package/remote_mtp_contract.py','from binding_common import require','from binding_common import require\nfrom workload_contract import counts')
edit('remote','package/remote_mtp_contract.py',"    require(job['schema']=='gemma4_resident_benchmark_v1' and job['mode']=='full' and job['promptCount'] in [128,4096]\n        and (job['chunkSize'],job['outputCount'],job['cut'],job['prefillPolicy'],job['timeoutSeconds'],job['residualDType'])==(64,16,7,'serial',300,'bfloat16')\n        and job['captureEvidence'] is False,'Closed ordinary metadata workload')","    counts(job)\n    require(job['captureEvidence'] is False,'Closed ordinary metadata workload')")
edit('remote','package/remote_mtp_contract.py','def validate_result(value,job,local,wrapper):','def validate_result(value,job,local,wrapper):\n    c=counts(job)')
for a,b in [("len(tokens)==16","len(tokens)==c['output']"),("job['promptCount']+15","c['frontier']"),("len(widths)+sum(accepted)==15","len(widths)+sum(accepted)==c['decode']"),("('decode',15)","('decode',c['decode'])")]:
 edit('remote','package/remote_mtp_contract.py',a,b,projects['remote']['package/remote_mtp_contract.py'].count(a))
edit('remote','package/dense_contract.py','from binding_common import require','from binding_common import require\nfrom workload_contract import target_extra_logical_bytes')
edit('remote','package/dense_contract.py',"{128:43568162,4096:90508322}[job['promptCount']]",'target_extra_logical_bytes(job)')
edit('remote','compare.py','import argparse','from package.workload_contract import counts\nimport argparse')
edit('remote','compare.py','decode=45e9/',"decode=counts(target['ordinaryJob'])['measuredDecodeTokens']*1e9/")
# Retained synthetic controls now exercise the same new closed grammar.
edit('remote','Tests/test_contract.py',"metadata_policy(value,dict(promptCount=128))","metadata_policy(value,fixtures()[0])")
edit('remote','Tests/test_contract.py',"metadata_policy(wrong,dict(promptCount=128))","metadata_policy(wrong,fixtures()[0])")
edit('remote','Tests/test_contract.py',"(0,'outputCount',128)","(0,'outputCount',129)")
edit('remote','Tests/test_contract.py',"nativeCacheBytesAfterRelease=0,guardObservationPolicy='gemma4_invocation_fresh_observation_v1',\n        guardMetrics=dict(schema='gemma4_guard_wall_counters_v1'),fullTargetLoaded=False,", """nativeCacheBytesAfterRelease=0,guardObservationPolicy='gemma4_remote_control_resource_boundaries_v1',
        controlResourceObservationPolicy='gemma4_remote_control_resource_boundaries_v1',
        controlResourceMetrics=dict(schema='gemma4_remote_control_resource_counters_v1',
            policy='gemma4_remote_control_resource_boundaries_v1',frameBytes=16384,sends=10,receives=10,
            completedOperations=20,entryResourceChecks=20,exitResourceChecks=20,innerLifetimeChecks=300,
            resourceValuesCachedAcrossOperations=False,snapshotResourceCadenceChanged=False,
            nativeCompletionFencesChanged=False,failed=False),
        guardMetrics=dict(schema='gemma4_guard_wall_counters_v1',records=[dict(category='wireSendCompleted',count=10),
            dict(category='wireReceiveCompleted',count=10)]),fullTargetLoaded=False,""")
edit('remote','jobs.py','C64 O16/chosen-depth1-or-2','C64 O16-or-128/chosen-depth1-or-2')
# Packed116 stays an exact predecessor, while the required final union is121.
edit('remote','activation.py',"json.loads(Path(required['packedHeadActivationExpectedSources']['path']).read_bytes())['files']==required['requiredFiles']","json.loads(Path(required['packedHeadActivationExpectedSources']['path']).read_bytes())['files']==required['packedHeadFiles']")
edit('remote','activation.py',"    assert sources['workspaceMutated'] is True", "    assert sources['workspaceMutated'] is True\n    assert str(build_path)==required['actualBuildReceipt']['path'] and sha(build_path)==required['actualBuildReceipt']['sha256']\n    assert str(sources_path)==required['actualSources']['path'] and sha(sources_path)==required['actualSources']['sha256']\n    assert sources['remoteControlSourceManifestSHA256']==required['remoteControlSourceManifestSHA256']\n    assert sources['remoteControlIntegrationSHA256']==required['remoteControlIntegrationSHA256']\n    assert sources['remoteControlBaseSources']==required['remoteControlBaseSources']\n    for name in ('remoteAssistantFreshGuardManifestSHA256','remoteVerificationDepthManifestSHA256','mtpOutputEnvelopeManifestSHA256'):\n        assert sources[name]==required[name]")
# Save intermediate source projection. Native binder and numeric adaptation follow.
for k,files in projects.items():
 for name,value in files.items():
  if original[k].get(name)!=value:
   p=D/'proposed'/k/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(value)
(D/'stage-state.json').write_text(json.dumps(dict(controlManifest=dict(path=str(CONTROL/'source-inputs.json'),sha256=sha(control_raw)),depthManifest=dict(path=str(DEPTH/'source-inputs.json'),sha256=sha(depth_raw)),bases={k:dict(path=str(BASES[k]/'source-inputs.json'),sha256=HASHES[k])for k in BASES},operations=[dict(kind=k,path=n,operations=v)for (k,n),v in ops.items()]),indent=2)+'\n')
print('staged',sum(original[k].get(n)!=s for k,files in projects.items() for n,s in files.items()))
