"""Fresh exact jobs and bounded actual metadata calls, only after a real build."""
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import uuid
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'package'))
from binding_common import parse,require
from build_binding import verify
from deploy import REMOTE,PRODUCT,digest
from worker_contract import WorkerSpec
from worker_processes import PipeWorkers
from gemma_inputs import write_json

def prepare(name,ownership):
    require(name and all(c.isalnum() or c in '-_' for c in name),'Case name')
    binding=verify();product=ROOT/'deployment/bundle'/PRODUCT
    require(product.stat().st_size==binding['nativeBytes'] and digest(product)==binding['nativeSHA256'],'Actual installed native binding')
    ownership=Path(ownership)
    require(ownership.resolve()==ownership and ownership.is_file() and not ownership.is_symlink()
            and 0<ownership.stat().st_size<=16384,'Ownership source path')
    ids=parse(ownership.read_bytes())
    require(type(ids) is list and len(ids)==2 and all(type(x) is list and 0<len(x)<128 for x in ids),'Two nonempty expert banks')
    require(all(all(type(i) is int for i in row) and row==sorted(set(row)) for row in ids)
            and sorted(ids[0]+ids[1])==list(range(128)),'Exact complete disjoint global IDs')
    directory=ROOT/'cases'/name;directory.mkdir(mode=0o700,parents=True)
    (directory/'metadata-controls').mkdir(mode=0o700)
    write_json(directory/'ownership.json',ids)
    common=dict(schema='gemma4_full_expert_correctness_job_v1',
        modelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B',metadataDirectory=REMOTE+'/metadata',
        promptFile=REMOTE+'/prompt.ids.json',promptFileSHA256=digest(ROOT/'deployment/prompt.ids.json'),
        requestID=str(uuid.uuid4()),membershipEpoch=str(uuid.uuid4()),buildIdentitySHA256=binding['nativeSHA256'],
        rankBuildSHA256=[binding['nativeSHA256']]*2,globalExpertIDsByRank=ids,timeoutSeconds=300)
    env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',HOME=str(Path.home()),LANG='C')
    calls=[]
    for mode in ('full','expert0','expert1'):
        job=dict(common,mode=mode,outputDirectory=REMOTE+'/runs/'+name+'-'+mode+'/sidecars')
        write_json(directory/(mode+'.json'),job)
        local=dict(job,metadataDirectory=str(ROOT/'deployment/metadata'),
            promptFile=str(ROOT/'deployment/prompt.ids.json'),outputDirectory=str(directory/(mode+'-unused-output')))
        local_job=directory/(mode+'-metadata-job.json');write_json(local_job,local)
        actions=['--describe','--check-arguments']+(['--check-local'] if mode=='expert0' else [])
        expected=None
        for action in actions:
            until=time.monotonic()+60
            def guard(_):require(time.monotonic()<until,'Original CPU metadata deadline')
            log=directory/'metadata-controls'/(mode+action)
            pipes=PipeWorkers((WorkerSpec((str(product),action,str(local_job)),env,'solo',None),),log,60,guard)
            value=None
            try:
                pipes.start()
                value=pipes.collect('benchmark',lambda _,raw:parse(raw))[0]
                pipes.finish()
            finally:pipes.close(kill=not pipes.complete_output)
            require(pipes.complete_output and not pipes.cleanup_errors
                    and [c.returncode for c in pipes.children]==[0],'Metadata child did not retire')
            if action=='--describe':
                expected=value;write_json(directory/('expected-'+mode+'.json'),value)
            elif action=='--check-arguments':require(value==expected,'Native argument/description disagreement')
            else:
                require(value['nativeExecuted'] is False and value['modelConstructed'] is False
                        and value['collectiveCreated'] is False and value['encoding']['oversizedRefused'] is True,
                        'Actual CPU/schema/encoding controls did not pass')
            calls.append(dict(mode=mode,action=action,exitCode=0,outputComplete=True,
                stdoutSHA256=digest(log/'worker-0.stdout'),stderrSHA256=digest(log/'worker-0.stderr')))
    write_json(directory/'preparation.json',dict(schema='gemma4_full_expert_preparation_v1',
        artifactBindingSHA256=digest(ROOT/'artifact-bindings.json'),packageSHA256=digest(ROOT/'deployment/package.json'),
        calls=calls,jobs={m:digest(directory/(m+'.json')) for m in ('full','expert0','expert1')},
        expected={m:digest(directory/('expected-'+m+'.json')) for m in ('full','expert0','expert1')},
        modelOrCollectiveOrGPUExecuted=False))
    return directory
