"""Bounded default/private tag checks and create-only coordinator products."""
import argparse
import json
import os
from pathlib import Path
import resource
import sys
RUN_ROOT=Path(__file__).resolve().parent
FROZEN=RUN_ROOT.parent/'cluster-native-shared-hardware-go-qualification-draft-20260917'
sys.path.insert(0,str(FROZEN))
from successor import verify_source
from command_results import validate_command
from check_process import run_owned
from go_coverage import API,completed,combine,discover,exact_filter,require_feature_passes
from guards import check_prepared as frozen_check_prepared,isolated_environment,load,save,sha
from inputs import BASE,ANCESTOR,WORKSPACE,GO,GO_SHA,GO_PACKAGES,GO_FILTER,TAG

PREFIX='github.com/eigeninference/d-inference/'
COMMAND='coordinator/cmd/coordinator'
def check_prepared():
    verify_source();return frozen_check_prepared()
def json_stream(raw):
    decoder=json.JSONDecoder();out=[]
    while raw.strip():
        raw=raw.lstrip();value,end=decoder.raw_decode(raw);out.append(value);raw=raw[end:]
    return out
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--phase',choices=['check','build','full'],required=True);parser.add_argument('--attempt',type=int,required=True);args=parser.parse_args()
    if args.attempt<1:raise ValueError('positive attempt')
    check_prepared()
    if sha(Path(GO))!=GO_SHA:raise ValueError('Go toolchain differs')
    inventory=sha(BASE/'projected-source.json')
    if args.phase!='check':
        prior=json.loads((RUN_ROOT/('check-'+str(args.attempt))/'checks.json').read_bytes())
        if prior.get('passed') is not True or prior['projectedSourceSHA256']!=inventory or prior.get('runnerManifestSHA256')!=sha(RUN_ROOT/'manifest.json'):raise ValueError('matching default/private checks required')
    output=RUN_ROOT/(args.phase+'-'+str(args.attempt));output.mkdir(mode=0o700)
    expected=load('expected-tests.json');os.chdir(WORKSPACE);isolated_environment()
    old_limit=resource.getrlimit(resource.RLIMIT_FSIZE);resource.setrlimit(resource.RLIMIT_FSIZE,(512*1024*1024,old_limit[1]))
    receipt={'phase':args.phase,'passed':False,'runnerManifestSHA256':sha(RUN_ROOT/'manifest.json'),'projectedSourceSHA256':inventory,'executions':[],'modelsOrRemoteExecuted':False}
    def execute(name,argv,timeout=300):
        check_prepared();entry={'name':name};receipt['executions'].append(entry)
        try:run_owned(argv,output,name,timeout,diagnostic_limit=16_777_216)
        finally:
            if (output/(name+'.json')).exists():entry['receiptSHA256']=sha(output/(name+'.json'))
            check_prepared();save(output/(name+'.source-check.json'),{'sourcePinsUnchanged':True})
        return (output/(name+'.stdout')).read_text()
    def test(name,private,packages,options):
        tags=['-tags',TAG] if private else []
        raw=execute(name,[GO,'test','-json','-race','-p','2','-count=1']+tags+options+['./'+p for p in packages])
        return [json.loads(line) for line in raw.splitlines() if line]
    def tag_check(private):
        name='private' if private else 'default';packages=[GO_PACKAGES[0],GO_PACKAGES[2],COMMAND]
        raw=execute(name+'-tag-selection',[GO,'list','-json']+(['-tags',TAG] if private else [])+['./'+p for p in packages])
        rows={v['ImportPath']:v for v in json_stream(raw)}
        if set(rows)!={PREFIX+p for p in packages}:raise ValueError('tag discovery packages')
        required={GO_PACKAGES[0]:['native_pair_hardware_observation.go','native_pair_hardware_observation_test.go'],GO_PACKAGES[2]:['native_pair_hardware.go'],COMMAND:['native_hardware_enabled.go','native_hardware_mode_test.go']}
        for p,names in required.items():
            active=set(rows[PREFIX+p].get('GoFiles',[])+rows[PREFIX+p].get('TestGoFiles',[]))
            if any((n in active)!=private for n in names):raise ValueError('private build tag selection differs')
        active=rows[PREFIX+COMMAND]['GoFiles']
        if ('native_hardware_disabled.go' in active)==private:raise ValueError('default stub build tag differs')
        save(output/(name+'-tag-selection.checked.json'),{'passed':True,'private':private})
    try:
        if args.phase=='check':
            for private in (False,True):
                name='private' if private else 'default';tag_check(private)
                coverage=completed(test(name+'-focused',private,GO_PACKAGES,['-timeout=120s','-run',GO_FILTER]),expected[name])
                if coverage!=expected[name]:raise ValueError('exact mandatory focus methods did not all pass')
                save(output/(name+'-focused.coverage.json'),coverage)
                wanted={PREFIX+COMMAND:expected['commandPrivate' if private else 'command']}
                command=validate_command(test(name+'-command',private,[COMMAND],['-timeout=120s']),wanted)
                save(output/(name+'-command.coverage.json'),command)
            receipt.update(defaultMethods=51,privateMethods=54,defaultCommandMethods=8,privateCommandMethods=11,defaultCommandPassed=7,privateCommandPassed=10,
                           commandExplicitSkip="TestMaintenanceProcessDoesNotServeOrSeedAdmin",maintenanceDatabaseBehaviorTested=False,raceDetector=True)
        elif args.phase=='build':
            products=[]
            for private in (False,True):
                name='private' if private else 'default';binary=output/('coordinator-'+name)
                execute(name+'-build',[GO,'build','-p','2']+(['-tags',TAG] if private else [])+['-o',str(binary),'./'+COMMAND])
                if not binary.is_file() or binary.is_symlink():raise ValueError('missing regular built coordinator')
                products.append({'path':str(binary),'sha256':sha(binary),'bytes':binary.stat().st_size,'private':private,'executed':False})
            receipt['products']=products
        else:
            catalog=discover(test('compiled-list',True,GO_PACKAGES,['-timeout=180s','-list','.']))
            old=json.loads((ANCESTOR/'go-all-1/discovery.json').read_bytes())['packages']
            want={k:sorted(v+(expected['newMethods'] if k==PREFIX+GO_PACKAGES[0] else [])) for k,v in old.items()}
            if catalog['packages']!=want:raise ValueError('compiled discovery differs from actual prior catalog plus three methods')
            save(output/'discovery.json',catalog)
            core_expected={k:v for k,v in want.items() if k!=API}
            parts=[completed(test('registry-protocol',True,GO_PACKAGES[:2],['-timeout=180s']),core_expected)]
            for index,names in enumerate(catalog['apiBatches'],1):
                part=completed(test('api-'+str(index),True,[GO_PACKAGES[2]],['-timeout=180s','-run',exact_filter(names)]),{API:names});parts.append(part)
            coverage=combine(parts,want);details=require_feature_passes(coverage,full=True)
            baseline=json.loads((ANCESTOR/'go-all-1/checks.json').read_bytes())['details']['ordinaryExplicitSkips']
            if details['ordinaryExplicitSkips']!=baseline:raise ValueError('new or changed explicit skip')
            save(output/'coverage.json',coverage);receipt['details']=details
        check_prepared();receipt['passed']=True
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE,old_limit);save(output/'checks.json',receipt)
    print(json.dumps({k:v for k,v in receipt.items() if k!='executions'},sort_keys=True),flush=True)

if __name__=='__main__':main()
