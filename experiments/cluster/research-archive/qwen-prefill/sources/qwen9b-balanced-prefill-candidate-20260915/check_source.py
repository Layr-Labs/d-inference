#!/usr/bin/env python3
"""Read-only local closure check. No compiler, native, network or candidate output access."""
from pathlib import Path
import hashlib
import json
import sys
from prepare_configuration import BASE, CASES, case_configuration, record

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def load(path):return json.loads(path.read_bytes())
def check(path,wanted):
    if digest(path)!=wanted:raise ValueError('Source/artifact pin differs: '+str(path))

def main():
    for x in load(BASE/'parent-lineage.json')['files']:
        check(BASE/x['path'],x['sha256']);check(Path(x['source']),x['sha256'])
    for name,key in [('metadata-lineage.json','exactDependencies'),('timing/source-lineage.json','exactSources')]:
        for x in load(BASE/name)[key]:
            check(BASE/x['copy'],x['sha256']);check(Path(x['source']),x['sha256'])
    for x in load(BASE/'upstream-inputs.json')['files']:check(Path(x['path']),x['sha256'])
    seen={}
    for name in CASES:
        c,owners,matrix,agreement=case_configuration(name)
        for filename,value in [('controller',c),('owner-rank0',owners[0]),('owner-rank1',owners[1]),('matrix',matrix)]:
            raw=(BASE/'cases'/name/'configuration'/(filename+'.json')).read_bytes()
            if raw!=record(value) or raw.count(b'\n')!=1:raise ValueError('Canonical case record differs')
        if name.endswith('-correctness') and (BASE/'cases'/name/'configuration/expected-agreement.json').read_bytes()!=record(agreement):
            raise ValueError('Prospective agreement differs')
        for x in load(BASE/'cases'/name/'run-pins.json')['files']:
            path=Path(x['path'])
            if str(path) in seen and seen[str(path)]!=x['sha256']:raise ValueError('Conflicting pin')
            seen[str(path)]=x['sha256']
    for path,wanted in seen.items():check(Path(path),wanted)
    sys.path.insert(0,str(BASE/'metadata'))
    from selected_source import load as derive_selected,derive
    actual=derive_selected()
    if actual!=load(BASE/'metadata/cut16.json'):raise ValueError('Cut16 recipe output differs')
    catalog=load(BASE/'metadata/selection/catalog.json');retained=load(BASE/'metadata/selection/retained-inputs.json')['nine']
    names=load(BASE/'metadata/selection/canonical-names.json');controls=load(BASE/'metadata/qualified-source-controls.json')
    if derive(catalog,retained,names,controls,4)!=load(BASE/'metadata/cut4.json'):raise ValueError('Cut4 recipe output differs')
    deployment=load(BASE/'deployment.json')
    for x in deployment['commonNativeFiles']:check(Path(x['source']),x['sha256'])
    for case in deployment['cases'].values():
        for rank in case['ranks']:
            if len(rank['files'])!=11 or len({x['path'] for x in rank['files']})!=11:raise ValueError('Deployment closure differs')
            for x in rank['files']:check(Path(x['source']),x['sha256'])
    print(json.dumps(dict(status='passed',uniqueRunInputs=len(seen),cases=len(CASES),nativeFiles=3,caseFilesPerRank=11,
        metadataCutsReproduced=[4,16],nativeModelRemoteOrCandidateOutputRead=False),sort_keys=True))

if __name__=='__main__':main()
