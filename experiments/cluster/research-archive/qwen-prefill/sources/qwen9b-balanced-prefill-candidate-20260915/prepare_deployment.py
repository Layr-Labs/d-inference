"""Create local deployment inventory/run pins; never copies to another host."""
from pathlib import Path
import hashlib
import json
from prepare_configuration import BASE, RESEARCH, REMOTE, CASES, KNOWN_HOSTS, record

def pin(path):
    return dict(path=str(path),bytes=path.stat().st_size,sha256=hashlib.sha256(path.read_bytes()).hexdigest())

def member(source, path, mode, role):
    x=pin(source)
    return dict(source=x.pop('path'),path=path,mode=mode,role=role,**x)

def main():
    controls=RESEARCH/'owner-retirement-controls-build-20260915/bundle-mtp'
    native=RESEARCH/'resident-lookahead128-bundle-20260915'
    common=[member(native/n,'native/'+n,'0755' if n=='darkbloom-cluster-worker' else '0644','retained_matched_native')
        for n in ['darkbloom-cluster-worker','mlx.metallib','mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal']]
    deployment=dict(schema='qwen9b_balanced_prefill_deployment_v1',remoteRoot=REMOTE,commonNativeFiles=common,cases={})
    for name in CASES:
        case=BASE/'cases'/name
        rank_entries=[]
        files=[]
        for n in ['darkbloom-owner-qualification','libDarkbloomClusterProtocol.dylib','libDarkbloomClusterBootstrap.dylib',
                  'libDarkbloomClusterProcess.dylib','libDarkbloomClusterRemote.dylib']:
            files.append(member(controls/n,name+'/'+n,'0755','coherent_fixed_owner'))
        for n in ['monitor.py','reference_resources.py','stage_checks/__init__.py','stage_checks/common.py']:
            files.append(member(BASE/'parent'/n,name+'/'+n,'0600','exact_resource_sampler'))
        files.append(member(case/'configuration/matrix.json',name+'/matrix.json','0600','unchanged_rdma_matrix'))
        for rank in range(2):
            owned=files+[member(case/f'configuration/owner-rank{rank}.json',name+'/owner.json','0600','rank_configuration')]
            rank_entries.append(dict(rank=rank,host=['darkbloom-24','darkbloom-48'][rank],files=owned))
        controller=BASE/'timing/runtime/owner-timing-controller' if name.endswith('-timing') else controls/'owner-controller'
        deployment['cases'][name]=dict(controller=pin(controller),ranks=rank_entries)
        paths=[BASE/'run_case.py',BASE/'prepare_configuration.py',case/'case.json',KNOWN_HOSTS]
        paths+=sorted((case/'configuration').glob('*.json'))
        paths+=[q for q in (BASE/'parent').rglob('*') if q.is_file() and '__pycache__' not in str(q)]
        paths+=[Path(x['source']) for x in common+rank_entries[0]['files']+rank_entries[1]['files']]
        paths+=[controller]+sorted(controller.parent.glob('*.dylib'))
        paths+=[controls/'bundle.json',native/'bundle.json',BASE/'partition-checks.json',BASE/'parent-lineage.json',
                BASE/'metadata/cut4.json',BASE/'metadata/cut16.json',BASE/'cut16-audit/audit_common.py']
        paths=list(dict.fromkeys(paths))
        (case/'run-pins.json').write_bytes(record(dict(schema='native_owner_run_pins_v1',files=[pin(q) for q in paths])))
    (BASE/'deployment.json').write_text(json.dumps(deployment,indent=2)+'\n')

if __name__=='__main__':main()
