"""Join actual pair execution/cleanup evidence; never accepts MTP model numerics."""
from package.workload_contract import counts
import argparse,hashlib,json,sys,re
from pathlib import Path
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'package'))
from activation import recheck
from root_run import verify_source
from evidence import Inputs,action,journal,processes,resources
from binding_common import parse,require
from remote_mtp_contract import validate_inputs,validate_result,validate_metadata_depth
from dense_contract import POLICY,metadata_policy
from jaccl_startup_stderr import validate_retained
from jobs import ROLES
from deploy import REMOTE

def completion_join(completion,terminal_raw,remote,role,expected_sha):
    actual=hashlib.sha256(terminal_raw).hexdigest()
    require(set(completion)=={'status','mode','run','terminalSHA256'} and completion['status']=='completed'
        and completion['mode']==role and completion['run']==remote and completion['terminalSHA256']==actual==expected_sha,
        'Collected terminal differs from the original successful launch receipt')

def sidecars(inputs,directory,result,capture):
    if 'files' not in result:
        require(directory.is_dir() and not any(directory.iterdir()),'Assistant emitted unexpected sidecars');return
    files=result['files'];seen=set()
    expected=[]
    for sample in result['samples']:
        ev=sample['evidence']
        if capture:
            expected.append(ev['finalRow']);expected.extend(x['file'] for x in ev['finalState']['entries'])
    require(files==expected and len(files)==(364 if capture else 0),'Final row/state file coverage')
    for row in files:
        name=row['name'];require(Path(name).name==name and name not in seen,'Duplicate/unsafe sidecar')
        seen.add(name);pin=inputs.pin(directory/name,64*1024**2)
        require(pin['sha256']==row['sha256'] and pin['bytes']==row['bytes'],'Sidecar identity')
    require({p.name for p in directory.iterdir()}==seen,'Unexpected/missing sidecars')

def compare(name):
    source_sha=verify_source();activation=recheck();inputs=Inputs();active_sha=inputs.pin(ROOT/'activation.json')['sha256']
    require(inputs.read(ROOT/'activation.json')==activation,'Activation changed')
    required=inputs.read(ROOT/'required-native-sources.json');build=inputs.read(activation['buildReceipt'])
    require(inputs.pin(activation['buildReceipt'])['sha256']==activation['buildReceiptSHA256'] and build['exitCode']==0
        and build['compilerReaped'] is True and build['groupAbsent'] is True and build['gpuExecuted'] is False
        and build['nativeSHA256']==activation['nativeSHA256'] and build['nativeBytes']==activation['nativeBytes'],'Actual build differs')
    require(inputs.pin(activation['sourceReceipt'],8*1024**2)['sha256']==activation['sourcesSHA256']==build['sourcesSHA256']
        and inputs.read(activation['sourceReceipt'],8*1024**2)['files']==required['requiredFiles'],'Exact compiled sources differ')
    for label,kind in [('deploy-prepare-1','deploy-prepare'),('install-darkbloom-24','install'),('install-darkbloom-48','install'),
        ('case-prepare-'+name,'case-prepare'),('metadata-'+name,'metadata'),('run-'+name,'run')]:action(inputs,label,kind,source_sha,active_sha)
    package=inputs.read(ROOT/'deployment/package.json');package_sha=inputs.pin(ROOT/'deployment/package.json')['sha256'];members={x['path']:x for x in package['files']}
    require(len(members)==len(package['files']) and package['schema']=='gemma4_benchmark_install_v1','Package member identity')
    for row in package['files']:
        rel=Path(row['path']);require(not rel.is_absolute() and '..' not in rel.parts,'Package path')
        pin=inputs.pin(ROOT/'deployment'/rel,200_000_000);require((pin['bytes'],pin['sha256'])==(row['bytes'],row['sha256']),'Packaged bytes changed')
    require(members['bundle/GemmaResidentBenchmark']['sha256']==activation['nativeSHA256'] and members['activation.json']['sha256']==active_sha,'Packaged build identity')
    for row in required['resources']:require(members[row['path']]==row,'Resource identity')
    for row in inputs.read(ROOT/'source-inputs.json')['members']:
        if row['path'].startswith('package/'):require(members[row['path'][8:]]==dict(row,path=row['path'][8:]),'Packaged supervisor differs')
    for _,host in ROLES:
        install=inputs.read(ROOT/f'installation-{host}-{package_sha[:12]}.json');observed=parse(install['stdout'])
        require(install['exitCode']==0 and install['stderr']=='' and install['packageSHA256']==package_sha
            and observed['status']=='installed' and observed['root']==REMOTE and observed['packageSHA256']==package_sha,'Installed role differs')
    case=ROOT/'cases'/name;outer=case/'pair';launch=inputs.read(outer/'receipt.json')
    require(launch['status']=='completed' and launch['kind']=='pair' and len(launch['results'])==2 and len(launch['quiescence'])==2
        and not any(launch.get(k) for k in ['errors','error','cleanupErrors','collectionErrors','cancellationErrors','peerCancellations']),'Pair launch or cleanup failed')
    require(launch['aliasReady']==dict(state='ready',address='169.254.70.47',bridgeAndManagementStable=True)
        and launch['aliasRelease']['restored'] is True and launch['aliasRelease']['exitCode']==0 and 'aliasExpiry' not in launch,'Alias retirement not established')
    alias_raw=inputs.raw(outer/'alias.stdout');alias_rows=[parse(x) for x in alias_raw.splitlines()]
    require(inputs.raw(outer/'alias.stderr')==b'' and alias_rows==launch['aliasRelease']['records'] and len(alias_rows)==1,'Alias raw identity')
    alias=alias_rows[0];require(alias['restored'] is True and alias['address']=='169.254.70.47' and alias['leaseSeconds']==600
        and not any(alias.get(k) for k in ['error','cleanupError']),'Alias restoration failed')
    require('inet 169.254.70.47 ' not in alias['afterRemove']['en1'] and '::ffff:169.254.70.47' not in alias['afterRemove']['gid'],'Alias remains')
    def stable(before,after):
        members=lambda s:sorted(re.findall(r'member: (\S+)',s['bridge0']))
        route=lambda s:re.findall(r'^\s*(?:gateway|interface):\s*(.*)$',s['managementRoute'],re.M)
        return members(before)==members(after) and before['bridge0'].splitlines()[0]==after['bridge0'].splitlines()[0] and route(before)==route(after) and 'status: active' in after['en1'] and 'PORT_ACTIVE' in after['gid']
    require(stable(alias['before'],alias['afterAdd']) and stable(alias['before'],alias['afterRemove'])
        and '::ffff:169.254.70.47' in alias['afterAdd']['gid'],'Raw bridge/management/alias lifecycle differs')
    metadata_lines=inputs.raw(ROOT/'root-actions'/('metadata-'+name)/'stdout').splitlines()
    require(all(x.startswith(b'owned-child pid ') or x.startswith(b'{') for x in metadata_lines),'Metadata outer framing')
    metadata_rows=[parse(x) for x in metadata_lines if x.startswith(b'{')];require(len(metadata_rows)==2,'Metadata role count')
    metadata={x['role']:x for x in metadata_rows};require(set(metadata)=={'target','assistant'},'Metadata roles')
    outcomes={};physical={}
    for role,host in ROLES:
        remote=REMOTE+'/runs/'+name+'-'+role;returned=outer/role
        row=[x for x in launch['results'] if x['mode']==role];require(len(row)==1,'Launch role duplicate');row=row[0]
        require(row['host']==host and row['exitCode']==0 and row['remoteDirectory']==remote,'Launch role host')
        jobs={}
        for file in ['job.json','local-mtp.json','remote-mtp.json']:
            raw=inputs.raw(case/role/file);require(raw==inputs.raw(returned/file),'Collected input changed');jobs[file]=parse(raw)
        job,local,wrapper=[jobs[x] for x in ['job.json','local-mtp.json','remote-mtp.json']]
        job_sha=inputs.pin(case/role/'job.json')['sha256'];local_sha=inputs.pin(case/role/'local-mtp.json')['sha256'];wrapper_sha=inputs.pin(case/role/'remote-mtp.json')['sha256']
        validate_inputs(job,local,wrapper,job_sha,local_sha,Path(remote));require(wrapper['role']==role,'Wrapper role')
        raw=inputs.raw(returned/'terminal.json',8*1024**2);terminal=parse(raw);completion_lines=inputs.raw(outer/(role+'.stdout')).splitlines()
        require(len(completion_lines)==1 and inputs.raw(outer/(role+'.stderr'))==b'' and inputs.raw(outer/(role+'.tar.stderr'))==b'','SSH completion/collection framing')
        completion_join(parse(completion_lines[0]),raw,remote,role,row['terminalSHA256'])
        require(terminal['status']=='completed' and terminal['mode']==role and terminal['exitCodes']==[0] and terminal['groupsAbsent'] is True
            and terminal['outputComplete'] is True and terminal['journalEmptyAndProcessesRetired'] is True and terminal['cleanupErrors']==[]
            and terminal['primaryFailure'] is None and 0<=terminal['elapsedSeconds']<315,'Native parent did not retire')
        require(terminal['packageSHA256']==package_sha and terminal['jobSHA256']==job_sha and terminal['localMTPConfigSHA256']==local_sha
            and terminal['remoteMTPConfigSHA256']==wrapper_sha and terminal['nativeOperation']=='execute-remote-mtp-dense-head'
            and terminal['encryptedRDMAEstablished'] is False and terminal['externalHTTPTTFTMeasured'] is False,'Physical input/claim differs')
        native_lines=inputs.raw(returned/'native/worker-0.stdout',8*1024**2).splitlines()
        require(len(native_lines)==1 and parse(native_lines[0])==terminal['result'] and inputs.raw(returned/'native/worker-0.stdin')==b'','Actual native output')
        stderr=validate_retained(inputs.raw(returned/'native/worker-0.stderr'), 'stage1' if role=='target' else 'stage0')
        if role=='target':require(stderr==terminal['startupStderr'],'Rank1 startup diagnostics differ')
        result=validate_result(terminal['result'],job,local,wrapper);outcomes[role]=result
        meta=metadata[role];require(meta==inputs.read(returned/'metadata/receipt.json') and meta['status']=='passed' and meta['exitCode']==0
            and meta['reaped'] is True and meta['groupAbsent'] is True and meta['metadataOnly'] is True and meta['gpuExecuted'] is False
            and meta['nativeSHA256']==activation['nativeSHA256'] and meta['packageSHA256']==package_sha and meta['jobSHA256']==job_sha
            and meta['localMTPConfigSHA256']==local_sha and meta['remoteMTPConfigSHA256']==wrapper_sha,'Actual metadata prerequisite differs')
        metadata_policy(meta['description'],job)
        validate_metadata_depth(meta['description'],local)
        desc=meta['description'];require(desc['job']==wrapper and desc['scopeSHA256']==result['scopeSHA256'] and desc['runtimeExecutionAuthorized'] is False,'Metadata/result scope')
        before=inputs.read(returned/'journal-before.json');after=inputs.read(returned/'journal-after.json');journal(before);journal(after,before)
        final=[x for x in launch['quiescence'] if x['host']==host];require(len(final)==1,'Missing exact quiescence host')
        journal(final[0]['observed']['journal'],before);processes(final[0]['observed']['processes'])
        gate=inputs.read(returned/'gate.json');owner=inputs.read(returned/'owner.json');native_launch=inputs.read(returned/'launch.json')
        require(owner['nativePIDs']==terminal['nativePIDs']==owner['nativePGIDs'] and len(terminal['nativePIDs'])==1
            and gate['ownerPID']==terminal['nativePIDs'][0] and type(gate['leaseFD']) is int and gate['leaseFD']>=0
            and gate['exclusiveLockHeld'] is True and gate['inheritedAcrossExec'] is True and gate['bytes']==0
            and gate['journalMutationPerformed'] is False and gate['protocolReleaseACK'] is False
            and all(gate[k]==before[k] for k in ['path','directoryDevice','directoryInode','fileDevice','fileInode']),'Inherited FD/process owner differs')
        processes(gate['processObservation'])
        require(native_launch['binary']==REMOTE+'/bundle/GemmaResidentBenchmark' and native_launch['job']==remote+'/job.json'
            and native_launch['jobSHA256']==job_sha and native_launch['localMTPConfigSHA256']==local_sha and native_launch['remoteMTPConfigSHA256']==wrapper_sha
            and native_launch['nativeOperation']=='execute-remote-mtp-dense-head' and native_launch['role']==role
            and native_launch['environment']['JACCL_RANK']==('1' if role=='target' else '0')
            and native_launch['environment']['JACCL_IBV_DEVICES']==REMOTE+'/matrix.json'
            and native_launch['environment']['JACCL_COORDINATOR']=='192.0.2.250:51361','Actual launch topology/inputs')
        physical[role]=resources(inputs.raw(returned/'resources.jsonl',8*1024**2));sidecars(inputs,returned/'sidecars',result,local['captureEvidence'])
    target,assistant=outcomes['target'],outcomes['assistant'];require(target['scopeSHA256']==assistant['scopeSHA256'],'Bilateral scope differs')
    for t,a in zip(target['samples'],assistant['samples']):
        require((t['requestID'],t['requestSHA256'],t['scopeSHA256'])==(a['requestID'],a['requestSHA256'],a['wireScopeSHA256']),'Bilateral request identity differs')
    measured=target['samples'][1:];decode=counts(target['ordinaryJob'])['measuredDecodeTokens']*1e9/sum(x['decodeNanoseconds'] for x in measured)
    inputs.recheck();require(verify_source()==source_sha,'Harness source changed')
    return dict(schema='gemma4_remote_mtp_packed_head_physical_execution_v1',status='passed',nativeSHA256=activation['nativeSHA256'],sourcesSHA256=activation['sourcesSHA256'],
        buildReceiptSHA256=activation['buildReceiptSHA256'],scopeSHA256=target['scopeSHA256'],physicalResources=physical,originalProcessesRetired=True,
        sameEmptyLeaseInodes=True,aliasRestored=True,protocolProcessReleaseACKClaimed=False,encryptedRDMAEstablished=False,
        gemmaWeightsExecuted=True,modelNumericalCorrectnessQualified=False,targetBatchNumericsQualified=False,matchedSoloComparisonPerformed=False,
        performanceQualified=False,throughputMeasured=True,targetProjectionPolicy=POLICY,
        qualificationInputs=activation['qualificationInputs'],decodeTPS=decode,selectedTokenIDs=measured[0]['selectedTokenIDs'],retainedInputPins=[x[3] for x in inputs.saved])
if __name__=='__main__':
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--case',required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    require(a.case and all(c.isalnum() or c in '-_' for c in a.case),'Case name');require(a.output.parent.resolve()==a.output.parent and not a.output.exists(),'Fresh output')
    result=compare(a.case)
    with a.output.open('x') as f:json.dump(result,f,indent=2,allow_nan=False);f.write('\n')
    print(json.dumps(dict(status='passed',output=str(a.output))))
