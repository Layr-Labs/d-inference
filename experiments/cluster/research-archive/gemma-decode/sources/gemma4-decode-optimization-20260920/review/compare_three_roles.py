"""Timestamp-only three-role qualification; never launches or changes a worker."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
HARNESS = ROOT/'harness'
BASE = ROOT.parent/'gemma4-execution-20260920'
OLD_NATIVE = '6115f51db204f8afe59b1e6b68d47074c7cad14bfde11e5acda477c290305034'
NEW_NATIVE = '84cbea53d012b0f6405491c90a25f3daaaaec8108b3b1ca95be320f392e04f75'
DEPENDENCIES = {
    'compare_results.py':'f2fe4c335636deb3d6b5938c3ac92cb17aae141f98328702609b7e64dcd856b1',
    'compare_results_overlap.py':'10741437b9dc9db7fc91e5fdc9f18e6860c2d13c723595b2f5f2b18405ef8c44',
    'package/jaccl_startup_stderr.py':'42c7f01b36392cb69cf177081fd6cf7a953963fd7cfb92b27ca0e784a5b82f29',
}
sha = lambda raw: hashlib.sha256(raw).hexdigest()
for name, wanted in DEPENDENCIES.items():
    if sha((HARNESS/name).read_bytes()) != wanted:
        raise ValueError('Frozen comparison dependency changed: '+name)
sys.path.insert(0,str(HARNESS)); sys.path.insert(0,str(HARNESS/'package'))
import compare_results_overlap as joined
original = joined.original
require = joined.require

GUARD_CATEGORIES = ['logicalGuard','entryGuard','ownerGuard','environmentGuard','osSnapshot',
                    'nativeSnapshot','outerNativeFault','wireSendCompleted','wireReceiveCompleted']
RESOURCE_VARIABLES = {'requestSHA256','minimumActualFreeBytes','maximumObservedActiveBytes',
    'maximumObservedNativePeakBytes','constructorObservedActiveBytes','constructorObservedNativePeakBytes'}
JOB_IDENTITY_AND_PATHS = {'buildIdentitySHA256','membershipEpoch','requestIDs','metadataDirectory',
                        'outputDirectory','promptFile'}
RETAINED_PINS = {}


def exact(actual, expected, label):
    require(type(actual) is type(expected),label+' type')
    if isinstance(expected,dict):
        require(actual.keys()==expected.keys(),label+' fields')
        for key in expected: exact(actual[key],expected[key],label+'.'+str(key))
    elif isinstance(expected,(list,tuple)):
        require(len(actual)==len(expected),label+' length')
        for i,(a,b) in enumerate(zip(actual,expected)): exact(a,b,label+f'[{i}]')
    else: require(actual==expected,label+' differs')


def pin(path, cap=32*1024**2):
    data = joined.raw(path,cap)
    return dict(path=str(path),bytes=len(data),sha256=sha(data))


def guard_counts(value):
    exact(set(value),{'schema','records','overflow','sameProcessClock','categoriesAreInclusive',
        'extraOSReads','extraNativeEvaluations','observerOverheadIncludedInRequestTiming'},'guard schema')
    for key,wanted in dict(schema='gemma4_guard_wall_counters_v1',overflow=False,sameProcessClock=True,
        categoriesAreInclusive=True,extraOSReads=0,extraNativeEvaluations=0,
        observerOverheadIncludedInRequestTiming=True).items(): exact(value[key],wanted,'guard '+key)
    exact([x['category'] for x in value['records']],GUARD_CATEGORIES,'guard category order')
    for row in value['records']:
        exact(set(row),{'category','count','nanoseconds','nestedLogicalGuardNanoseconds'},'guard record')
        for key in ('count','nanoseconds','nestedLogicalGuardNanoseconds'):
            joined.integer(row[key],key)
        require(row['nestedLogicalGuardNanoseconds']<=row['nanoseconds'],'Nested time exceeds interval')
    return {x['category']:x['count'] for x in value['records']}


def same_cadence(new,old):
    exact(new['guardObservationPolicy'],old['guardObservationPolicy'],'guard observation policy')
    exact(new['guardObservationPolicy'],'gemma4_invocation_fresh_observation_v1','fresh guard policy')
    exact(guard_counts(new['guardMetrics']),guard_counts(old['guardMetrics']),'whole-owner guard counts')
    result=[]
    for a,b in zip(new['samples'],old['samples']):
        exact(a['guardMetrics']['boundary'],b['guardMetrics']['boundary'],'guard sample boundary')
        counts={}
        for phase in ('prefill','decode'):
            counts[phase]=guard_counts(a['guardMetrics'][phase])
            exact(counts[phase],guard_counts(b['guardMetrics'][phase]),f'ordinal{a["ordinal"]} {phase} guard counts')
        # Timestamps may change; every observed phase/frontier must remain.
        for x,y in zip(a['frames'],b['frames']):
            exact({k:x[k] for k in ('sequence','phase','offset','tokenCount')},
                  {k:y[k] for k in ('sequence','phase','offset','tokenCount')},'frame cadence')
            exact([{k:v for k,v in p.items() if k!='timestampNanoseconds'} for p in x['ownerPhases']],
                  [{k:v for k,v in p.items() if k!='timestampNanoseconds'} for p in y['ownerPhases']],
                  'owner phase cadence')
        result.append(dict(ordinal=a['ordinal'],warmup=a['warmup'],counts=counts))
    return dict(globalCounts=guard_counts(new['guardMetrics']),requests=result)


def same_budget(new,old):
    a,b=new['resources'],old['resources']
    exact(set(a),set(b),'resource fields')
    exact({k:v for k,v in a.items() if k not in RESOURCE_VARIABLES},
          {k:v for k,v in b.items() if k not in RESOURCE_VARIABLES},'same-role actual reservation')
    for value in (a,b):
        require(value['actualAllocatorBoundsUsed'] is True and value['operationalResourceChecksApplied'] is True
                and value['reclaimableUsedForAdmission'] is False and value['minimumActualFreeBytes']>=6*1024**3
                and value['selectedTensorCount']==value['completedTensorCount'] and value['observationCount']>0,
                'Native resource completion/floor')
        require(len(value['namedArrays'])==len(value['namedAllocationBounds']) and
                all(type(n) is int and n>=x['bytes']>0 for x,n in zip(value['namedArrays'],value['namedAllocationBounds']))
                and value['namedNativeReserveBytes']==sum(value['namedAllocationBounds']), 'Native allocation bounds')
        require(value['requestSHA256']==new['samples'][0]['requestSHA256'] if value is a
                else value['requestSHA256']==old['samples'][0]['requestSHA256'],'Reservation request binding')
    # No manufactured serial allocation baseline: compare each new policy only
    # against its actual accepted v7 counterpart, including its full allowance.
    return dict(namedNativeReserveBytes=a['namedNativeReserveBytes'],hostEvidenceReserveBytes=a['hostEvidenceReserveBytes'],
                prefillAllowance=a.get('prefillAllowance'),observationCount=a['observationCount'])


def matched_workload(new,old):
    exact(set(new['job']),set(old['job']),'job field domain')
    exact({k:v for k,v in new['job'].items() if k not in JOB_IDENTITY_AND_PATHS},
          {k:v for k,v in old['job'].items() if k not in JOB_IDENTITY_AND_PATHS},'before/after semantic workload')
    exact(new['sourceLoad'],old['sourceLoad'],'same artifact/selection/quantization/read accounting')
    exact(new['planSHA256'],old['planSHA256'],'same native Plan')
    for a,b in zip(new['samples'],old['samples']):
        exact(a['binding'],b['binding'],'same actual request geometry and state layout')
        exact(a['selectedTokenIDs'],b['selectedTokenIDs'],'before/after complete token sequence')


def full_row(path,sample):
    value=joined.decode(original.sidecar(path,sample['finalRow']))
    require(value['shape']==[1,262144] and len(value['values'])==262144 and
            all(type(x) in (int,float) and math.isfinite(x) for x in value['values']) and
            value['values'].index(max(value['values']))==sample['selectedTokenIDs'][-1], 'Full final row/argmax')
    return value


def validate_role(case,kind,mode,host,native,package_sha=None):
    folder=case/kind/mode
    # Recheck small authority/clock records after all numerical reads. Sidecar
    # bytes are independently checked against their pinned native descriptors.
    small=[case/kind/'receipt.json',case/kind/(mode+'.stdout'),case/kind/(mode+'.stderr')]
    small += [folder/name for name in ['terminal.json','job.json','gate.json','owner.json',
              'journal-before.json','journal-after.json','native/worker-0.stdout','native/worker-0.stderr',
              'resources.jsonl']]
    for path in small:
        retained=pin(path); RETAINED_PINS[str(path)]=retained
        if path.suffix=='.json':joined.decode(joined.raw(path))
    original.validate_launch(case,kind,mode,host)
    proof=joined.join_role(case,kind,mode,host)
    path=case/kind/mode
    value=original.load(path,mode)
    exact(value['job']['buildIdentitySHA256'],native,'actual native identity')
    if package_sha is not None:
        exact(joined.read(path/'terminal.json')['packageSHA256'],package_sha,'installed package')
    exact(value['job']['captureEvidence'],True,'capture required')
    for k,want in dict(promptCount=4096,chunkSize=64,outputCount=16,cut=7,residualDType='bfloat16',timeoutSeconds=300).items():
        exact(value['job'][k],want,'fixed workload '+k)
    require(value['encryptedRDMAEstablished'] is False and value['runtimeServingEnabled'] is False,
            'Diagnostic transport scope')
    return path,value,proof


def compare():
    source_inputs=joined.read(HERE/'source-inputs.json',131072)
    for item in source_inputs['files']:
        exact(pin(Path(item['path']),max(item['bytes'],1)),item,'frozen comparison input')
    build=joined.read(ROOT/'build/timestamp-build-2.json')
    applied=joined.read(ROOT/'build/applied-timestamp-2.json')
    exact(build['nativeSHA256'],NEW_NATIVE,'qualified new native')
    require(build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True,'Actual native build')
    exact(build['sourcesSHA256'],pin(ROOT/'build/applied-timestamp-2.json')['sha256'],'new source composition')
    exact(applied['baselineSourcesSHA256'],pin(BASE/'build/applied-uncached-sidecars.json')['sha256'],'v7 source ancestry')
    exact(applied['changes'],['UTC formatter reuse only'],'bounded runtime change')
    package=joined.read(HARNESS/'deployment/package.json'); package_sha=pin(HARNESS/'deployment/package.json')['sha256']
    natives=[x for x in package['files'] if x['path'].endswith('/GemmaResidentBenchmark')]
    require(len(natives)==1 and natives[0]['sha256']==NEW_NATIVE and natives[0]['bytes']==build['nativeBytes'],
            'Packaged actual native')
    for host in ('darkbloom-24','darkbloom-48'):
        install=joined.read(HARNESS/f'installation-{host}-{package_sha[:12]}.json')
        require(install['exitCode']==0 and install['stderr']=='' and install['packageSHA256']==package_sha,
                'Actual host installation')
        exact(joined.decode(install['stdout'])['packageSHA256'],package_sha,'Remote installation pin')
    old_serial=BASE/'cases/p4096-cut7-c64-serial-v7'; old_pair=BASE/'cases/p4096-cut7-c64-overlap-v7'
    new_solo=HARNESS/'cases/p4096-cut7-c64-serial-v1'; new_pair=HARNESS/'cases/p4096-cut7-c64-overlap-v1'
    accepted=joined.read(old_pair/'comparison-overlap.json')
    require(accepted['status']=='passed' and accepted['benchmarkNativeSHA256']==OLD_NATIVE,'Accepted v7 reference')
    roles=[('solo','full','darkbloom-48'),('pair','stage0','darkbloom-24'),('pair','stage1','darkbloom-48')]
    old=[];new=[]; cadence=[];budgets=[]
    for index,(kind,mode,host) in enumerate(roles):
        a=validate_role(old_serial if index==0 else old_pair,kind,mode,host,OLD_NATIVE)
        b=validate_role(new_solo if index==0 else new_pair,kind,mode,host,NEW_NATIVE,package_sha)
        exact(a[2],accepted['retainedEvidenceJoins'][[0,3,4][index]],'Accepted v7 retained role')
        matched_workload(b[1],a[1]); cadence.append(same_cadence(b[1],a[1]));budgets.append(same_budget(b[1],a[1]))
        old.append(a);new.append(b)
    job=new[0][1]['job']
    for _,value,_ in new:
        exact({k:v for k,v in value['job'].items() if k not in ('mode','outputDirectory','prefillPolicy')},
              {k:v for k,v in job.items() if k not in ('mode','outputDirectory','prefillPolicy')},'New matched jobs')
    require(new[0][1]['job']['prefillPolicy']=='serial' and
            all(v[1]['job']['prefillPolicy']=='oneChunkLookahead' for v in new[1:]),'Exact new policies')
    require(new[1][1]['scopeSHA256']==new[2][1]['scopeSHA256']!=new[0][1]['scopeSHA256'],'Policy-bound bilateral scope')
    require(len({x[2]['nativePID'] for x in new})==3,'Distinct new native owners')
    rows=components=state_bytes=cross_rows=cross_components=cross_bytes=0
    for ordinal in range(4):
        samples=[v[1]['samples'][ordinal] for v in new]
        for sample in samples[1:]:
            exact(sample['selectedTokenIDs'],samples[0]['selectedTokenIDs'],'New matched tokens')
            exact(sample['requestSHA256'],samples[0]['requestSHA256'],'New matched request')
        row=full_row(new[0][0],samples[0]); exact(full_row(new[2][0],samples[2]),row,'New full final row')
        states=[original.state(v[0],sample) for v,sample in zip(new,samples)]
        for state,domain in zip(states,[(0,30),(0,7),(7,30)]):
            exact(set(state),original.state_keys(*domain),'Exact state key domain')
        exact({**states[1],**states[2]},states[0],'New combined KV states')
        rows+=1;components+=len(states[0]);state_bytes+=sum(len(x[3]) for x in states[0].values())
        for i,prior in enumerate(old):
            sample=prior[1]['samples'][ordinal]
            if i!=1:
                exact(full_row(prior[0],sample),row,'v7 complete row');cross_rows+=1
            prior_state=original.state(prior[0],sample)
            exact(states[i],prior_state,'Same-role v7 native KV bytes/layout')
            cross_components+=len(prior_state);cross_bytes+=sum(len(x[3]) for x in prior_state.values())
    timings={}
    for i,name in enumerate(('solo','lookahead0','lookahead1')):
        before=original.summarize(old[i][1]['samples'],4096,16);after=original.summarize(new[i][1]['samples'],4096,16)
        timings[name]=dict(before=before,after=after,prefillRateRatio=after['prefillTPS']/before['prefillTPS'],
                          decodeRateRatio=after['decodeTPS']/before['decodeTPS'],guardCountsEqual=True)
    for item in source_inputs['files']:
        exact(pin(Path(item['path']),max(item['bytes'],1)),item,'Source/expected input recheck')
    for path,item in RETAINED_PINS.items():
        exact(pin(Path(path)),item,'Retained execution input recheck')
    return dict(schema='gemma4_timestamp_three_role_comparison_v1',status='passed',
        oldNativeSHA256=OLD_NATIVE,newNativeSHA256=NEW_NATIVE,packageSHA256=package_sha,
        inputSourceSHA256=pin(HERE/'source-inputs.json')['sha256'],
        workload=dict(promptTokens=4096,chunkTokens=64,outputTokens=16,cut=7,mtpEnabled=False,promptSHA256=job['promptFileSHA256']),
        newFullRowsCompared=rows,newStateComponentsCompared=components,newStateBytesCompared=state_bytes,
        beforeAfterFullRowsCompared=cross_rows,beforeAfterStateComponentsCompared=cross_components,beforeAfterStateBytesCompared=cross_bytes,
        timings=timings,retainedNewEvidence=[v[2] for v in new],retainedV7Evidence=[v[2] for v in old],
        retainedInputPins=list(RETAINED_PINS.values()),
        exactCadence=cadence,sameRoleBudgetChecks=budgets,newSerialPairExecuted=False,
        crossBuildAndUUIDDifferencesExplicitlyAllowed=True,fullStateAndRowBytesActuallyCompared=True,
        transport='plaintext JACCL/RDMA',crossProcessClockOriginsJoined=False,externalTTFTMeasured=False,
        representativeWorkloadStudyComplete=False,plannerEnabled=False)


def markdown(report):
    lines=['Timestamp-only comparison passed: new solo and lookahead pair match each other and accepted v7 tokens, complete final rows and native KV state bytes. All global and per-request prefill/decode guard counts match v7.','',
           '| Role | Prefill TPS before → after | Decode TPS before → after | Measured requests |',
           '|---|---:|---:|---:|']
    for role,value in report['timings'].items():
        a,b=value['before'],value['after']
        lines.append(f'| {role} | {a["prefillTPS"]:.3f} → {b["prefillTPS"]:.3f} | {a["decodeTPS"]:.3f} → {b["decodeTPS"]:.3f} | {a["measurements"]} / {b["measurements"]} |')
    lines+=['','P4096/C64/O16/cut7, one warmup excluded and three measured requests per role. TPS is total measured tokens divided by total measured same-process duration. No new serial pair was needed. Native/launch/lease/resource/alias checks passed through the retained original helpers. This is one fixed prompt, plaintext RDMA and internal timing; no external TTFT or general workload claim.',
            '',f'New pair versus solo: {report["newFullRowsCompared"]} complete rows, {report["newStateComponentsCompared"]} state components. Before/after across the three roles: {report["beforeAfterFullRowsCompared"]} complete rows, {report["beforeAfterStateComponentsCompared"]} components. Four requests including warmup are numerically checked.','']
    return '\n'.join(lines)


if __name__=='__main__':
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output-dir',required=True,type=Path);args=p.parse_args()
    require(args.output_dir.is_absolute() and args.output_dir==args.output_dir.resolve() and not args.output_dir.exists(),
            'Fresh canonical output directory required')
    report=compare();args.output_dir.mkdir()
    payload=(json.dumps(report,indent=2,sort_keys=True,allow_nan=False)+'\n').encode()
    with (args.output_dir/'comparison.json').open('xb') as stream:stream.write(payload)
    with (args.output_dir/'REPORT.md').open('x') as stream:stream.write(markdown(report))
    print(json.dumps(dict(status='passed',sha256=sha(payload),output=str(args.output_dir/'comparison.json'))))
