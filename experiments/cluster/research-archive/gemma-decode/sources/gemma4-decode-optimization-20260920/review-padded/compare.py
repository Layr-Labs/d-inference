"""Padded-control qualification, reusing frozen physical/numerical validators."""
import argparse
import hashlib
import json
from pathlib import Path
import stat
import policy
import decode_summary

c=policy.base
exact,require=policy.exact,policy.require
HERE=Path(__file__).resolve().parent
ROOT=HERE.parent
H2=ROOT/'harness-v2'
NEW_NATIVE='d7859728bbda3c1b4a0d65766e1bc44b964143d6e7b493e944fb05d3e09ca769'


def file_hash(path,cap):
    before=path.lstat();require(stat.S_ISREG(before.st_mode) and before.st_nlink==1 and 0<before.st_size<=cap,
                                'Bounded ordinary deployed native required')
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024**2),b''):digest.update(block)
    after=path.stat();require((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==
        (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns),'Native changed during read')
    return dict(path=str(path),bytes=before.st_size,sha256=digest.hexdigest())


def pins_unchanged(inputs):
    for row in inputs['files']:exact(c.pin(Path(row['path']),max(row['bytes'],1)),row,'Pinned source/evidence')


def binding():
    # Actual successful build identity supplied by root, never a prospective SHA.
    build_path=ROOT/'build/control-build-1.json';build=c.joined.read(build_path)
    require(build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True
            and build['gpuExecuted'] is False,'Actual successful native build')
    exact(build['nativeSHA256'],NEW_NATIVE,'Actual new native')
    exact(build['sourcesSHA256'],c.pin(ROOT/'build/applied-control-frame.json')['sha256'],'Actual source composition')
    applied=c.joined.read(ROOT/'build/applied-control-frame.json')
    exact(applied['priorSourcesSHA256'],c.pin(ROOT/'build/applied-timestamp-2.json')['sha256'],'Timestamp ancestry')
    exact(applied['integrationSHA256'],c.pin(ROOT/'control-frame-draft/integration.json')['sha256'],'Only reviewed framing overlay')
    package_path=H2/'deployment/package.json';package=c.joined.read(package_path);package_pin=c.pin(package_path)
    rows=[x for x in package['files'] if x['path']=='bundle/GemmaResidentBenchmark']
    require(len(rows)==1,'One deployed native')
    native=file_hash(H2/'deployment/bundle/GemmaResidentBenchmark',128*1024**2)
    exact(native['sha256'],NEW_NATIVE,'Deployed native file hash')
    exact(native['bytes'],build['nativeBytes'],'Actual build size')
    exact(rows[0],dict(path='bundle/GemmaResidentBenchmark',bytes=native['bytes'],sha256=NEW_NATIVE),'Package native binding')
    installs=[]
    for host in ('darkbloom-24','darkbloom-48'):
        path=H2/f'installation-{host}-{package_pin["sha256"][:12]}.json';value=c.joined.read(path)
        require(value['exitCode']==0 and value['stderr']=='' and value['packageSHA256']==package_pin['sha256'],
                'Both actual installations required')
        response=c.joined.decode(value['stdout'])
        exact(response['status'],'installed','Remote installation completion')
        exact(response['packageSHA256'],package_pin['sha256'],'Remote package hash')
        installs.append(c.pin(path))
    return dict(build=c.pin(build_path),package=package_pin,deployedNative=native,installations=installs)


def within_cohort(values):
    job=values[0][1]['job']
    for _,value,_ in values:
        exact({k:v for k,v in value['job'].items() if k not in ('mode','outputDirectory','prefillPolicy')},
              {k:v for k,v in job.items() if k not in ('mode','outputDirectory','prefillPolicy')},'Matched new semantic workload')
        exact(value['planSHA256'],values[0][1]['planSHA256'],'New Plan')
    require(job['prefillPolicy']=='serial' and all(x[1]['job']['prefillPolicy']=='oneChunkLookahead' for x in values[1:]),
            'Only solo/overlap roles')
    require(values[1][1]['scopeSHA256']==values[2][1]['scopeSHA256']!=values[0][1]['scopeSHA256'],
            'Policy-bound new bilateral scope')
    require(len({v[2]['nativePID'] for v in values})==3,'Distinct new native owners')


def numerical(current,baselines):
    totals=dict(newFullRows=0,newComponents=0,newStateBytes=0,
                baselines={name:dict(fullRows=0,stateComponents=0,stateBytes=0) for name in baselines})
    for ordinal in range(4):
        samples=[value[1]['samples'][ordinal] for value in current]
        for sample in samples[1:]:
            exact(sample['selectedTokenIDs'],samples[0]['selectedTokenIDs'],'New complete token sequence')
            exact(sample['requestSHA256'],samples[0]['requestSHA256'],'New exact request')
        row=c.full_row(current[0][0],samples[0]);exact(c.full_row(current[2][0],samples[2]),row,'New complete final row')
        states=[c.original.state(value[0],sample) for value,sample in zip(current,samples)]
        for state,bounds in zip(states,[(0,30),(0,7),(7,30)]):exact(set(state),c.original.state_keys(*bounds),'Complete native state domain')
        exact({**states[1],**states[2]},states[0],'New combined KV state')
        totals['newFullRows']+=1;totals['newComponents']+=len(states[0]);totals['newStateBytes']+=sum(len(x[3]) for x in states[0].values())
        for name,baseline in baselines.items():
            for index,prior in enumerate(baseline):
                sample=prior[1]['samples'][ordinal]
                exact(sample['selectedTokenIDs'],samples[index]['selectedTokenIDs'],'Baseline tokens '+name)
                if index!=1:
                    exact(c.full_row(prior[0],sample),row,'Complete baseline row '+name);totals['baselines'][name]['fullRows']+=1
                state=c.original.state(prior[0],sample)
                exact(states[index],state,'Exact same-role native state bytes '+name)
                totals['baselines'][name]['stateComponents']+=len(state)
                totals['baselines'][name]['stateBytes']+=sum(len(x[3]) for x in state.values())
    return totals


def compare():
    inputs=c.joined.read(HERE/'source-inputs.json',131072);pins_unchanged(inputs)
    deployed=binding();package_sha=deployed['package']['sha256']
    timestamp=c.joined.read(ROOT/'review/actual-timestamp-1/comparison.json')
    exact(timestamp['status'],'passed','Accepted timestamp baseline')
    exact(timestamp['newNativeSHA256'],c.NEW_NATIVE,'Actual timestamp baseline native')
    locations={
      'v7':(c.BASE/'cases/p4096-cut7-c64-serial-v7',c.BASE/'cases/p4096-cut7-c64-overlap-v7',c.OLD_NATIVE),
      'timestamp':(c.HARNESS/'cases/p4096-cut7-c64-serial-v1',c.HARNESS/'cases/p4096-cut7-c64-overlap-v1',c.NEW_NATIVE),
      'padded':(H2/'cases/p4096-cut7-c64-serial-v2',H2/'cases/p4096-cut7-c64-overlap-v2',NEW_NATIVE)}
    cohorts={};cadence=[];budgets=[]
    roles=[('solo','full','darkbloom-48'),('pair','stage0','darkbloom-24'),('pair','stage1','darkbloom-48')]
    for name,(solo,pair,native) in locations.items():
        cohorts[name]=[c.validate_role(solo if i==0 else pair,kind,mode,host,native,package_sha if name=='padded' else None)
                       for i,(kind,mode,host) in enumerate(roles)]
        within_cohort(cohorts[name])
    for i,rank in enumerate((None,0,1)):
        v7,old,new=(cohorts[name][i] for name in ('v7','timestamp','padded'))
        exact(v7[2],timestamp['retainedV7Evidence'][i],'Accepted v7 authority')
        exact(old[2],timestamp['retainedNewEvidence'][i],'Accepted timestamp authority')
        c.matched_workload(old[1],v7[1]);c.same_cadence(old[1],v7[1]);c.same_budget(old[1],v7[1])
        c.matched_workload(new[1],old[1]);c.matched_workload(new[1],v7[1])
        cadence.append(policy.cadence(new[1],old[1],rank));budgets.append(policy.budget(new[1],old[1],rank))
    counts=numerical(cohorts['padded'],{k:v for k,v in cohorts.items() if k!='padded'})
    timings={}
    decode_profiles={}
    for i,role in enumerate(('solo','lookahead0','lookahead1')):
        timings[role]={name:c.original.summarize(value[i][1]['samples'],4096,16) for name,value in cohorts.items()}
        decode_profiles[role]={name:decode_summary.summarize(value[i][1]) for name,value in cohorts.items()}
        a,b=timings[role]['timestamp'],timings[role]['padded']
        timings[role]['paddedVsTimestamp']=dict(prefillRateRatio=b['prefillTPS']/a['prefillTPS'],decodeRateRatio=b['decodeTPS']/a['decodeTPS'])
    pins_unchanged(inputs)
    for path,row in c.RETAINED_PINS.items():exact(c.pin(Path(path)),row,'Retained execution file unchanged')
    exact(c.pin(Path(deployed['package']['path'])),deployed['package'],'Package unchanged')
    exact(file_hash(Path(deployed['deployedNative']['path']),128*1024**2),deployed['deployedNative'],'Native unchanged')
    return dict(schema='gemma4_padded_three_role_comparison_v1',status='passed',deployment=deployed,
        inputSourceSHA256=c.pin(HERE/'source-inputs.json')['sha256'],nativeSHA256=NEW_NATIVE,
        workload=timestamp['workload'],timings=timings,numerical=counts,decodeProfiles=decode_profiles,
        cadence=cadence,budgetDeltas=budgets,prefixDerivation=policy.geometry(),
        retainedEvidence={name:[x[2] for x in values] for name,values in cohorts.items()},
        retainedInputPins=list(c.RETAINED_PINS.values()),
        newSerialPairExecuted=False,fullStateAndRowBytesActuallyCompared=True,
        transport='plaintext JACCL/RDMA',crossProcessClockOriginsJoined=False,externalTTFTMeasured=False,
        representativeWorkloadStudyComplete=False,plannerEnabled=False)


def markdown(value):
    lines=['Padded control comparison passed for matched solo and lookahead pair. Tokens, complete final rows and native state bytes match both timestamp v1 and v7.','',
           '| Role | v7 prefill / decode TPS | Timestamp prefill / decode TPS | Padded prefill / decode TPS |',
           '|---|---:|---:|---:|']
    for role,row in value['timings'].items():
        cells=[f'{row[k]["prefillTPS"]:.3f} / {row[k]["decodeTPS"]:.3f}' for k in ('v7','timestamp','padded')]
        lines.append('| '+role+' | '+' | '.join(cells)+' |')
    lines+=['','Each arm: P4096/C64/O16/cut7, one excluded warmup and three measured requests. TPS is total measured tokens divided by total same-process time. Four requests per role have numerical evidence checked.',
            '', 'Solo cadence and budget are unchanged. Each stage adds one actual rounded 16-KiB native control frame plus 32-KiB host allowance. Decode now has three completed sends and three receives per token; logical checks are exactly 65/63 per rank/token. Global counts also include every probe and begin/ready/request-retired/model-released control. Resource floors, native fault handling, native ownership and physical retirement proofs remain required.',
            '', 'These are internal timings of one fixed plaintext-RDMA workload. No external TTFT, encrypted transport or general throughput claim.','']
    lines+=['| Padded role | Total ms/token | Owner span | Evaluation | Logical guard | OS snapshot | Wire minus nested guard |',
            '|---|---:|---:|---:|---:|---:|---:|']
    for role,versions in value['decodeProfiles'].items():
        x=versions['padded'];p=x['localMillisecondsPerToken'];g=x['guardCategories'];w=x['wireGuardMillisecondsPerToken']
        numbers=(p['tokenInterval'],p['ownerSpan'],p['evaluation'],g['logicalGuard']['millisecondsPerToken'],
                 g['osSnapshot']['millisecondsPerToken'],w['wireExcludingNestedGuard'])
        lines.append('| '+role+' | '+' | '.join(f'{n:.3f}' for n in numbers)+' |')
    lines+=['','All intervals use only their own process clock. Owner and guard categories overlap; do not add columns. Wire minus nested guard still includes peer computation, scheduling and native completion. JSON includes every guard category/call count, graph/staging/commit phases and before/after-owner intervals for all three versions.','']
    return '\n'.join(lines)


if __name__=='__main__':
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('--output-dir',required=True,type=Path);args=parser.parse_args()
    require(args.output_dir.is_absolute() and args.output_dir==args.output_dir.resolve() and not args.output_dir.exists(),
            'New canonical result directory required')
    result=compare();args.output_dir.mkdir()
    raw=(json.dumps(result,indent=2,sort_keys=True,allow_nan=False)+'\n').encode()
    with (args.output_dir/'comparison.json').open('xb') as f:f.write(raw)
    with (args.output_dir/'REPORT.md').open('x') as f:f.write(markdown(result))
    print(json.dumps(dict(status='passed',output=str(args.output_dir),sha256=c.sha(raw))))
