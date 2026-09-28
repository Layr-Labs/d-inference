"""Accept one actual tiny-state run after source, process and resource joins."""
import argparse
import hashlib
import json
from pathlib import Path
from activation import recheck
from evidence import Inputs, ROOT, action, journal, processes, resources
from root_run import verify_source
from binding_common import parse, require
from local_mtp_contract import validate_result
from solo_contract import validate_result as validate_solo_result

REMOTE='/Users/developer/DarkbloomDev/gemma4-local-mtp-20260920-v1'


def completion_join(completion, terminal_raw, remote):
    require(set(completion)=={'status','mode','run','terminalSHA256'}
        and completion['status']=='completed' and completion['mode']=='full'
        and completion['run']==remote
        and completion['terminalSHA256']==hashlib.sha256(terminal_raw).hexdigest(),
        'Collected terminal does not match original SSH completion')


def compare(CASE):
    source_sha=verify_source();activation=recheck();inputs=Inputs()
    activation_pin=inputs.pin(ROOT/'activation.json');activation_sha=activation_pin['sha256']
    require(inputs.read(ROOT/'activation.json')==activation,'Activation changed')
    build=inputs.read(Path(activation['buildReceipt']))
    require(inputs.pin(Path(activation['buildReceipt']))['sha256']==activation['buildReceiptSHA256']
        and build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True
        and build['gpuExecuted'] is False and build['nativeSHA256']==activation['nativeSHA256']
        and build['nativeBytes']==activation['nativeBytes'],'Actual build receipt differs')
    sources=inputs.read(Path(activation['sourceReceipt']),8*1024**2)
    require(inputs.pin(Path(activation['sourceReceipt']),8*1024**2)['sha256']==build['sourcesSHA256']==activation['sourcesSHA256'],
        'Actual compiled source composition differs')
    native_sources={x['path']:x for x in sources['files']}
    require(len(native_sources)==len(sources['files']),'Duplicate native source')
    required=inputs.read(ROOT/'required-native-sources.json')
    for row in required['requiredFiles']:require(native_sources[row['path']]==row,'Native control/entry source differs')
    for name,kind in [('deploy-prepare-1','deploy-prepare'),('install-1','install'),
                      ('case-prepare-'+CASE,'case-prepare'),('metadata-'+CASE,'metadata'),('run-'+CASE,'run')]:
        action(inputs,name,kind,source_sha,activation_sha)

    package=inputs.read(ROOT/'deployment/package.json');package_pin=inputs.pin(ROOT/'deployment/package.json')
    require(package['schema']=='gemma4_benchmark_install_v1','Package schema differs')
    package_rows={x['path']:x for x in package['files']}
    require(len(package_rows)==len(package['files']),'Duplicate package file')
    for row in package['files']:
        rel=Path(row['path']);require(not rel.is_absolute() and '..' not in rel.parts,'Package path')
        pin=inputs.pin(ROOT/'deployment'/rel,200_000_000)
        require((pin['bytes'],pin['sha256'])==(row['bytes'],row['sha256']),'Deployed package bytes differ')
    require(package_rows['bundle/GemmaResidentBenchmark']['sha256']==activation['nativeSHA256']
        and package_rows['bundle/GemmaResidentBenchmark']['bytes']==activation['nativeBytes']
        and package_rows['activation.json']['sha256']==activation_sha,'Actual packaged native/activation differs')
    for row in required['resources']:require(package_rows[row['path']]==row,'Native resource changed')
    for row in inputs.read(ROOT/'source-inputs.json')['members']:
        if row['path'].startswith('package/'):
            name=row['path'][8:]
            require(package_rows[name]==dict(row,path=name),'Packaged supervisor differs')
    installation=inputs.read(ROOT/f'installation-darkbloom-48-{package_pin["sha256"][:12]}.json')
    installed=parse(installation['stdout'])
    require(installation['exitCode']==0 and installation['stderr']==''
        and installation['packageSHA256']==package_pin['sha256']
        and installed['status']=='installed' and installed['root']==REMOTE
        and installed['packageSHA256']==package_pin['sha256'],'48 GiB installation did not complete')

    case=ROOT/'cases'/CASE;outer=case/'solo';returned=outer/'full'
    operation=inputs.read(case/'operation.json')['operation']
    job_raw=inputs.raw(case/'full.json');job=parse(job_raw)
    require(job['promptCount'] in (128,4096) and (job['mode'],job['chunkSize'],job['outputCount'],job['cut'],job['prefillPolicy'])
        ==('full',64,16,7,'serial') and type(job['captureEvidence']) is bool
        and (operation=='execute-solo' or job['captureEvidence'] is False)
        and job['buildIdentitySHA256']==activation['nativeSHA256'],'Metadata workload changed')
    description_lines=inputs.raw(ROOT/'root-actions'/('metadata-'+CASE)/'stdout').splitlines()
    require(description_lines and all(x.startswith(b'owned-child pid ') for x in description_lines[:-1]),'Metadata output framing')
    metadata=parse(description_lines[-1]);description=metadata['description']
    require(metadata['status']=='passed' and metadata['exitCode']==0 and metadata['reaped'] is True
        and metadata['groupAbsent'] is True and metadata['metadataOnly'] is True and metadata['gpuExecuted'] is False
        and metadata['nativeSHA256']==activation['nativeSHA256']
        and metadata['jobSHA256']==hashlib.sha256(job_raw).hexdigest()
        and metadata['packageSHA256']==package_pin['sha256']
        and description['job']==job and description['metadataOnly'] is True
        and description['runtimeExecutionAuthorized'] is False and description['servingEnabled'] is False,
        'Actual metadata-only native prerequisite differs')
    launch=inputs.read(outer/'receipt.json')
    require(launch['status']=='completed' and launch['kind']=='solo'
        and not any(launch.get(k) for k in ('errors','error','cleanupErrors','collectionErrors','cancellationErrors'))
        and 'aliasReady' not in launch and 'aliasRelease' not in launch and 'aliasExpiry' not in launch,'Root physical launch failed')
    remote=REMOTE+'/runs/'+CASE+'-full'
    require(launch['results']==[dict(mode='full',host='darkbloom-48',exitCode=0,remoteDirectory=remote)]
        and len(launch['quiescence'])==1 and launch['quiescence'][0]['host']=='darkbloom-48','Wrong role/host or incomplete cleanup')
    require(inputs.raw(outer/'full.stderr')==b'' and inputs.raw(outer/'full.tar.stderr')==b'','SSH/collection stderr')
    completion_lines=inputs.raw(outer/'full.stdout').splitlines();require(len(completion_lines)==1,'Completion framing')
    terminal_raw=inputs.raw(returned/'terminal.json');completion_join(parse(completion_lines[0]),terminal_raw,remote)
    terminal=parse(terminal_raw)
    require(terminal['schema']=='gemma4_benchmark_terminal_v1' and terminal['encryptedRDMAEstablished'] is False
        and terminal['externalHTTPTTFTMeasured'] is False and terminal['status']=='completed' and terminal['mode']=='full' and terminal['exitCodes']==[0]
        and terminal['groupsAbsent'] is True and terminal['outputComplete'] is True
        and terminal['journalEmptyAndProcessesRetired'] is True and terminal['cleanupErrors']==[]
        and terminal['primaryFailure'] is None and 0<=terminal['elapsedSeconds']<315
        and terminal['packageSHA256']==package_pin['sha256']
        and terminal['jobSHA256']==hashlib.sha256(job_raw).hexdigest(),'Native physical owner did not retire')
    require(inputs.raw(returned/'job.json')==job_raw,'Collected job differs')
    native_lines=inputs.raw(returned/'native/worker-0.stdout',8*1024**2).splitlines()
    require(len(native_lines)==1 and parse(native_lines[0])==terminal['result']
        and inputs.raw(returned/'native/worker-0.stderr')==b'' and inputs.raw(returned/'native/worker-0.stdin')==b'',
        'Native output/transcript differs')
    config_raw=inputs.raw(case/'local-mtp.json');config=parse(config_raw)
    config_sha=hashlib.sha256(config_raw).hexdigest()
    require(inputs.raw(returned/'local-mtp.json')==config_raw
        and terminal['localMTPConfigSHA256']==config_sha and terminal['nativeOperation']==operation,'Collected local config/operation differs')
    if operation=='execute-solo':
        result=validate_solo_result(terminal['result'],job)
        require(result['scopeSHA256']==description['scopeSHA256'],'Ordinary input scope differs')
    else:
        result=validate_result(terminal['result'],job,config,config_sha,operation)
        require(result['ordinaryInputScopeSHA256']==description['scopeSHA256'],'Ordinary input scope differs')
    before=inputs.read(returned/'journal-before.json');after=inputs.read(returned/'journal-after.json')
    journal(before);journal(after,before)
    final=launch['quiescence'][0]['observed'];journal(final['journal'],before);processes(final['processes'])
    gate=inputs.read(returned/'gate.json');owner=inputs.read(returned/'owner.json')
    native_launch=inputs.read(returned/'launch.json')
    require(native_launch['binary']==REMOTE+'/bundle/GemmaResidentBenchmark'
        and native_launch['job']==remote+'/job.json'
        and native_launch['jobSHA256']==terminal['jobSHA256']
        and native_launch['localMTPConfigSHA256']==config_sha and native_launch['nativeOperation']==operation
        and len(native_launch['binaryIdentity'])==6 and native_launch['binaryIdentity'][3]==activation['nativeBytes'],
        'Collected same-PID exec identity differs')
    require(len(terminal['nativePIDs'])==1 and owner['nativePIDs']==terminal['nativePIDs']
        and owner['nativePGIDs']==terminal['nativePIDs'] and gate['ownerPID']==terminal['nativePIDs'][0]
        and type(gate['leaseFD']) is int and gate['leaseFD']>=0
        and gate['exclusiveLockHeld'] is True and gate['inheritedAcrossExec'] is True
        and gate['journalMutationPerformed'] is False and gate['protocolReleaseACK'] is False
        and gate['bytes']==0 and all(gate[k]==before[k] for k in ('path','directoryDevice','directoryInode','fileDevice','fileInode')),
        'Original same-PID inherited lease/owner identity differs')
    processes(gate['processObservation'])
    resource=resources(inputs.raw(returned/'resources.jsonl',8*1024**2))
    if not config['captureEvidence']:
        require((returned/'sidecars').is_dir() and not any((returned/'sidecars').iterdir()),'Unexpected model sidecars')
    inputs.recheck();require(verify_source()==source_sha,'Harness source changed')
    generation=[x if operation=='execute-solo' else x['generation'] for x in result['samples']]
    generation=[x for x in generation if not x['warmup']]
    prefill=sum(job['promptCount'] for x in generation)*1e9/sum(x['prefillNanoseconds'] for x in generation)
    decode=45e9/sum(x['decodeNanoseconds'] for x in generation)
    return dict(schema='gemma4_decode_cohort_physical_execution_v1',status='passed',nativeOperation=operation,
        nativeSHA256=activation['nativeSHA256'],sourceSHA256=activation['sourcesSHA256'],
        buildReceiptSHA256=activation['buildReceiptSHA256'],activationSHA256=activation_sha,
        sourceManifestSHA256=source_sha,packageSHA256=package_pin['sha256'],
        nativeScopeSHA256=result['scopeSHA256'],configSHA256=config_sha,
        physicalResources=resource,originalProcessRetired=True,sameEmptyLeaseInode=True,
        aliasUsed=False,protocolReleaseACKClaimed=False,gemmaWeightsExecuted=True,
        modelNumericalCorrectnessQualified=False,distributedQualified=False,
        conditioningQualified=result.get('conditioningQualificationPassed',False),
        throughputMeasured=True,performanceQualified=False,matchedSoloComparisonPerformed=False,
        prefillTPS=prefill,decodeTPS=decode,selectedTokenIDs=generation[0]['selectedTokenIDs'],
        measuredProposalTokens=sum(x.get('proposalTokens',0) for x in generation),
        measuredAcceptedProposalTokens=sum(x.get('acceptedProposalTokens',0) for x in generation),
        retainedInputPins=[x[3] for x in inputs.saved])



if __name__=='__main__':
    parser=argparse.ArgumentParser(allow_abbrev=False);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--case',required=True)
    args=parser.parse_args();require(args.output.parent.resolve()==args.output.parent and not args.output.exists(),'Fresh canonical output required')
    require(args.case and all(c.isalnum() or c in '-_' for c in args.case),'Case name')
    value=compare(args.case)
    with args.output.open('x') as f:json.dump(value,f,indent=2,allow_nan=False);f.write('\n')
    print(json.dumps(dict(status='passed',output=str(args.output))))
