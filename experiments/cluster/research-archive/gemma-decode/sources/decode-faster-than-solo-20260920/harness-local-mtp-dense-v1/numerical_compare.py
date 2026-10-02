"""Read-only P128 same-build ordinary versus local-MTP numerical replay."""
import argparse
from collections import Counter
from decimal import Decimal
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import uuid

from recorded_math import WIDTH, canonical, digest, equal, logical_bytes, parse_json, require, sha_string
from snapshot import snapshot

ROOT = Path(__file__).resolve().parent
COMPONENTS = ('kv.keys', 'kv.position_offsets', 'kv.values')
JOURNAL = ('path', 'directoryDevice', 'directoryInode', 'fileDevice', 'fileInode')
POLICY='gemma4_verification_packed_m1_dense_serial_head_v1'
HELPERS = {'recorded_math.py': 'f166a6a27c20021c30c62e6966e63583b9ecab955a3b23af64869cd821f25914',
           'snapshot.py': '46dfa5689fba4358412c6c4ce03a759ca71d5c30bcde9df995a46c4aad97873b'}


def text_hash(parts):
    return digest('\n'.join(parts).encode())


def integer(value, low=0, high=2**63-1):
    require(type(value) is int and low <= value <= high, 'Invalid bounded integer')
    return value


class Inputs:
    def __init__(self): self.pins = {}

    def read(self, path, bound=8*1024**2, keep=True, empty=False):
        path = Path(path)
        require(path.is_absolute() and path.parent.resolve() == path.parent, 'Noncanonical retained parent')
        info = path.lstat()
        require(info.st_nlink == 1, 'Input has multiple links')
        value = snapshot(path, bound, keep=keep, empty=empty)
        pin = dict(path=str(path), bytes=value['size_bytes'], sha256=value['sha256'], identity=list(value['identity']))
        if str(path) in self.pins: equal(self.pins[str(path)], pin, 'Input changed across reads')
        self.pins[str(path)] = pin
        return value['raw'] if keep else pin

    def json(self, path, bound=8*1024**2): return parse_json(self.read(path, bound))

    def recheck(self):
        for name, pin in self.pins.items():
            s = Path(name).lstat()
            require(list((s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)) == pin['identity'],
                    'Retained input identity changed during comparison')


def journal(value, before=None):
    require(set(value) == set(JOURNAL) | {'bytes','sha256','exclusiveObservationLockAcquired','journalMutationPerformed'},
            'Journal schema differs')
    require(value['path'] == '/Users/developer/.darkbloom/cluster-device/native-device.lease'
            and integer(value['bytes']) == 0 and value['sha256'] == digest(b'')
            and value['exclusiveObservationLockAcquired'] is True and value['journalMutationPerformed'] is False,
            'Canonical journal not observed empty')
    for key in JOURNAL[1:]: integer(value[key],1)
    if before: require(all(value[k] == before[k] for k in JOURNAL), 'Journal inode changed')


def processes(value):
    require(value['command'] == ['/bin/ps','-Aww','-o','pid=,uid=,comm='] and value['prohibited'] == [],
            'Native/owner absence was not observed')
    integer(value['observerPID'],1); integer(value['processCount'],1); sha_string(value['stdoutSHA256'])
    start = integer(value['observedStartMonotonicNS']); end = integer(value['observedEndMonotonicNS'])
    require(start <= end <= start+4_000_000_000, 'Process observation deadline differs')


def resources(raw):
    rows = [parse_json(line) for line in raw.splitlines()]
    require(2 <= len(rows) <= 2000 and rows[0]['phase'] == 'prelaunch' and rows[-1]['phase'] == 'postflight'
            and sum(x['phase']=='prelaunch' for x in rows) == sum(x['phase']=='postflight' for x in rows) == 1,
            'Resource anchors/count differ')
    previous = 0
    for row in rows:
        page = re.search(r'page size of (\d+) bytes',row['rawVMStat'])
        free = re.search(r'Pages free:\s+(\d+)\.',row['rawVMStat'])
        swap = re.search(r'used\s*=\s*([0-9.]+)([MG])',row['rawMemory'])
        require(page and free and swap, 'Missing raw resource fields')
        require(integer(row['actualFreeBytes']) == int(page[1])*int(free[1]) >= 6*1024**3
                and integer(row['pressureLevel']) == int(row['rawMemory'].splitlines()[0]) == 1
                and Decimal(str(row['reportedSwapBytes'])) == Decimal(swap[1])*(1024**2 if swap[2]=='M' else 1024**3) == 0
                and row['acPower'] is True and "Now drawing from 'AC Power'" in row['rawPower'],
                'Raw resource replay or unchanged floor differs')
        start = integer(row['startedMonotonicNS']); end = integer(row['completedMonotonicNS'])
        require(previous <= start <= end <= start+10_000_000_000, 'Resource clock order/deadline differs')
        previous = end
    require(previous-rows[0]['startedMonotonicNS'] < 315_000_000_000, 'Resource lifetime exceeds parent bound')
    return dict(samples=len(rows),minimumActualFreeBytes=min(x['actualFreeBytes'] for x in rows),rawReplayPassed=True)


def physical(inputs, case, native_sha, native_bytes, package_sha, expected_operation):
    outer = case/'solo'; returned = outer/'full'
    launch = inputs.json(outer/'receipt.json')
    require(launch['status'] == 'completed' and launch['kind'] == 'solo'
            and not any(launch.get(k) for k in ('errors','error','cleanupErrors','collectionErrors','cancellationErrors','peerCancellations'))
            and not any(k in launch for k in ('aliasReady','aliasRelease','aliasExpiry')),
            'Outer ordinary/local owner did not retire')
    require(len(launch['results']) == len(launch['quiescence']) == 1, 'Unexpected roles')
    result = launch['results'][0]
    require(result['mode'] == 'full' and result['host'] == 'darkbloom-48' and result['exitCode'] == 0,
            'Wrong physical role or SSH failure')
    for name in ('full.stderr','full.tar.stderr'):
        require(inputs.read(outer/name,1024,empty=True) == b'', 'SSH/collection stderr')
    lines = inputs.read(outer/'full.stdout',16384).splitlines()
    terminal_raw = inputs.read(returned/'terminal.json')
    require(len(lines) == 1, 'SSH completion framing')
    equal(parse_json(lines[0]),dict(status='completed',mode='full',run=result['remoteDirectory'],
                                  terminalSHA256=digest(terminal_raw)), 'SSH-to-terminal join differs')
    terminal = parse_json(terminal_raw)
    require(terminal['schema'] == 'gemma4_benchmark_terminal_v1' and terminal['status'] == 'completed'
            and terminal['mode'] == 'full' and terminal['exitCodes'] == [0]
            and all(terminal[k] is True for k in ('groupsAbsent','outputComplete','journalEmptyAndProcessesRetired'))
            and terminal['primaryFailure'] is None and terminal['cleanupErrors'] == []
            and type(terminal['elapsedSeconds']) in (int,float) and math.isfinite(terminal['elapsedSeconds'])
            and 0 < terminal['elapsedSeconds'] < 315 and terminal['packageSHA256'] == package_sha
            and terminal['nativeOperation'] == expected_operation, 'Actual native completion differs')
    job_raw = inputs.read(case/'full.json',16384); job = parse_json(job_raw)
    require(inputs.read(returned/'job.json',16384) == job_raw and terminal['jobSHA256'] == digest(job_raw), 'Job identity differs')
    require(job['buildIdentitySHA256'] == native_sha, 'Same-build native identity differs')
    stdout = inputs.read(returned/'native/worker-0.stdout')
    require(stdout.endswith(b'\n') and stdout.count(b'\n') == 1, 'Native complete result framing')
    equal(parse_json(stdout[:-1]),terminal['result'],'Native stdout differs from terminal result')
    for name in ('worker-0.stderr','worker-0.stdin'):
        require(inputs.read(returned/'native'/name,1024,empty=True) == b'', 'Unexpected native stderr/stdin')
    before=inputs.json(returned/'journal-before.json'); journal(before)
    journal(inputs.json(returned/'journal-after.json'),before)
    observed=launch['quiescence'][0]
    require(observed['host']=='darkbloom-48','Quiescence host differs')
    journal(observed['observed']['journal'],before); processes(observed['observed']['processes'])
    gate=inputs.json(returned/'gate.json'); owner=inputs.json(returned/'owner.json')
    pids=terminal['nativePIDs']; require(len(pids)==1,'Native PID count'); integer(pids[0],1)
    require(owner['nativePIDs']==owner['nativePGIDs']==pids and gate['ownerPID']==pids[0]
            and all(gate[k]==before[k] for k in JOURNAL) and gate['bytes']==0
            and gate['exclusiveLockHeld'] is True and gate['inheritedAcrossExec'] is True
            and gate['journalMutationPerformed'] is False and gate['protocolReleaseACK'] is False,
            'Original inherited native owner lease differs')
    integer(gate['leaseFD']); processes(gate['processObservation'])
    native_launch=inputs.json(returned/'launch.json')
    remote=result['remoteDirectory']; require('/runs/' in remote,'Remote run scope')
    require(native_launch['binary']==remote.split('/runs/')[0]+'/bundle/GemmaResidentBenchmark'
            and native_launch['job']==remote+'/job.json' and native_launch['jobSHA256']==terminal['jobSHA256']
            and native_launch['nativeOperation']==expected_operation and len(native_launch['binaryIdentity'])==6
            and native_launch['binaryIdentity'][3]==native_bytes,'Native same-PID exec binding differs')
    config_raw=inputs.read(case/'local-mtp.json',16384)
    require(inputs.read(returned/'local-mtp.json',16384)==config_raw
            and terminal['localMTPConfigSHA256']==native_launch['localMTPConfigSHA256']==digest(config_raw),
            'Retained wrapper config identity differs')
    return job,terminal['result'],parse_json(config_raw),digest(config_raw),returned,dict(
        terminalSHA256=digest(terminal_raw),nativePID=pids[0],resources=resources(inputs.read(returned/'resources.jsonl')),
        originalOwnerRetired=True,sameEmptyJournal=True)


def workload(job):
    require(job['schema']=='gemma4_resident_benchmark_v1' and job['mode']=='full'
            and job['promptCount']==128 and job['chunkSize']==64 and job['outputCount']==16 and job['cut']==7
            and job['residualDType']=='bfloat16' and job['prefillPolicy']=='serial' and job['timeoutSeconds']==300,
            'Comparator requires exact P128/C64/O16/cut7 ordinary arithmetic')
    ids=job['requestIDs']; require(len(ids)==4 and len(set(ids))==4,'Fresh request IDs')
    for value in ids+[job['membershipEpoch']]: require(str(uuid.UUID(value))==value,'Noncanonical UUID')
    return {k:v for k,v in job.items() if k not in ('requestIDs','membershipEpoch','outputDirectory','captureEvidence')}


def request_hash(job, ordinal, prompt):
    profile=digest('|'.join(['qwen-stage-generation-profile-v1','registered_gemma4_26b_forward_validation_v1',
                            '262144','2816','bfloat16','8192','512','128','8320']).encode())
    tokens=digest(','.join(map(str,prompt)).encode())
    return text_hash(['qwen-stage-generation-request-v1',profile,job['requestIDs'][ordinal],
                      'prompt='+tokens,'chunk=64','output=16','stop='])


def ordinary_scope(job, plan, requests):
    return text_hash(['gemma4-resident-benchmark-v1',job['membershipEpoch'],job['buildIdentitySHA256'],plan,
        job['promptFileSHA256'],'cut=7','warmup=1','measure=3','mtp=false',
        'capture='+str(job['captureEvidence']).lower()]+requests+['prefill=serial'])


def binding(value, load):
    require(value['target']==load['target']=='full-reference' and value['maximumTokens']==144 and value['maximumChunkTokens']==64
            and value['probePrefillTokens']==2 and value['probeDecodeTokens']==1
            and value['selectedTensorCount']==1339, 'Full target state binding differs')
    for key in ('planSHA256','artifactSHA256','configurationSHA256','parameterLayoutSHA256'):
        require(value[key]==load[key], 'Binding differs from actual source load: '+key); sha_string(value[key])
    require(value['selectedBytes']==load['loadedTensorBytes']
            and value['readAccountingSHA256']==digest(canonical(load['readAccounting'])), 'Actual read accounting differs')
    rows=['attention-state-layout-v1','maximumTokens=144','maximumChunkTokens=64','prefix=false','speculation=false']
    require(len(value['layers'])==30,'Missing full state layers')
    for index,layer in enumerate(value['layers']):
        full=index%6==5; dtype=layer['dtype']
        require(dtype in ('float16','bfloat16','float32'),'Unknown observed KV dtype')
        equal(layer,dict(localIndex=index,globalIndex=index,kvHeads=2 if full else 8,
            headDimension=512 if full else 256,window=0 if full else 1024,dtype=dtype),'Layer geometry/identity differs')
        rows.append(f"{index}|{index}|{layer['kvHeads']}|{layer['headDimension']}|{'full' if full else 1024}|{dtype}")
    require(value['stateLayoutSHA256']==text_hash(rows),'State layout fingerprint differs')


class Sidecars:
    def __init__(self, inputs, returned, files):
        self.inputs=inputs; self.root=returned/'sidecars'; self.used=set(); self.files={}
        require(len(files)==364 and self.root.resolve()==self.root,'Expected four final rows and360 state files')
        for row in files:
            require(set(row)=={'name','bytes','sha256'} and re.fullmatch('[a-z0-9_.-]{1,128}',row['name'])
                    and not row['name'].startswith('.') and row['name'] not in self.files,'Sidecar name/record differs')
            integer(row['bytes'],1,16*1024**2); sha_string(row['sha256']); self.files[row['name']]=row
        require(set(x.name for x in self.root.iterdir())==set(self.files),'Missing or extra sidecars')

    def read(self, row):
        require(self.files.get(row['name'])==row and row['name'] not in self.used,'Sidecar binding reused/substituted')
        data=self.inputs.read(self.root/row['name'],16*1024**2)
        require(len(data)==row['bytes'] and digest(data)==row['sha256'],'Sidecar bytes/hash differs')
        self.used.add(row['name']); return data


def finite(raw, dtype):
    if dtype=='bfloat16':
        require(all((bits&0x7f80)!=0x7f80 for (bits,) in struct.iter_unpack('<H',raw)),'Nonfinite BF16 state')
    else:
        require(all(math.isfinite(x) for (x,) in struct.iter_unpack('<e' if dtype=='float16' else '<f',raw)),
                'Nonfinite native state')


def state(value, bind, sidecars, ordinal):
    require(set(value)=={'frontier','fingerprint','entries'} and value['frontier']==143
            and len(value['entries'])==90,'Missing full final state')
    result={}; identities=[]
    for entry,(layer,component) in zip(value['entries'],[(i,c) for i in range(30) for c in COMPONENTS]):
        require(set(entry)=={'localLayerIndex','globalLayerIndex','component','dtype','sha256','shape','byteCount','logicalRange','file'},
                'State component schema differs')
        require((entry['localLayerIndex'],entry['globalLayerIndex'],entry['component'])==(layer,layer,component),
                'State domain/order differs')
        geometry=bind['layers'][layer]; position=component=='kv.position_offsets'
        dtype='int32' if position else geometry['dtype']
        shape=[1] if position else [1,geometry['kvHeads'],143,geometry['headDimension']]
        count=math.prod(shape)*WIDTH[dtype]; logical=[] if position else [0,143]
        equal([entry['dtype'],entry['shape'],entry['byteCount'],entry['logicalRange']],
              [dtype,shape,count,logical],'State temporal geometry/type differs')
        equal(entry['file'],dict(name=f'request-{ordinal}-state-{layer}-{component}.bin',bytes=count,sha256=entry['sha256']),
              'State filename/hash binding differs')
        raw=sidecars.read(entry['file']); require(digest(raw)==sha_string(entry['sha256']),'Native state hash differs')
        if position: require(raw==struct.pack('<i',143),'Actual stored position differs')
        else: finite(raw,dtype)
        identity=f"{layer}|{component}|{shape}|{dtype}|{count}|{entry['sha256']}"
        if not position: identity+='|range=0:143'
        identities.append(identity); result[(layer,component)]=(dtype,shape,logical,raw)
    require(value['fingerprint']==text_hash(['cbv2-owned-attention-state-v2',bind['stateLayoutSHA256'],'tokens=143']+identities),
            'Actual final snapshot fingerprint differs')
    return result


def row(value, sidecars, ordinal, token):
    require(value['name']==f'request-{ordinal}-final-row.json','Final row name differs')
    record=parse_json(sidecars.read(value)); raw=logical_bytes(record,262144,record['dtype'])
    require(record['values'].index(max(record['values']))==token,'Final full row argmax differs')
    return record['dtype'],raw


def compare(args):
    inputs=Inputs()
    for name,pin in HELPERS.items(): require(digest(inputs.read(ROOT/name))==pin,'Frozen numeric helper changed')
    build=inputs.json(args.build_receipt); source=inputs.read(args.source_receipt)
    native=inputs.read(args.native_file,128*1024**2,keep=False); package_raw=inputs.read(args.package_manifest)
    package=parse_json(package_raw)
    require(package['schema']=='gemma4_benchmark_install_v1'
            and len({x['path'] for x in package['files']})==len(package['files']),'Actual package schema/duplicate files')
    matches=[x for x in package['files'] if x['path']=='bundle/GemmaResidentBenchmark']
    require(build['exitCode']==0 and build['compilerReaped'] is True and build['groupAbsent'] is True
            and build['gpuExecuted'] is False and build['sourcesSHA256']==digest(source)
            and build['nativeSHA256']==native['sha256'] and build['nativeBytes']==native['bytes']
            and len(matches)==1 and matches[0]['sha256']==native['sha256'] and matches[0]['bytes']==native['bytes'],
            'Actual same compiled native/package/source receipt join differs')
    a=physical(inputs,args.ordinary_case,native['sha256'],native['bytes'],digest(package_raw),'execute-solo')
    operation=inputs.json(args.mtp_case/'operation.json')['operation']
    require(operation in ('execute-local-mtp-dense','qualify-mtp-conditioning-dense'),'MTP operation differs')
    b=physical(inputs,args.mtp_case,native['sha256'],native['bytes'],digest(package_raw),operation)
    ja,ordinary,_,_,pa,physical_a=a; jb,mtp,config,config_sha,pb,physical_b=b
    equal(workload(ja),workload(jb),'Semantic prompt/model/build/math differs')
    require(set(ja['requestIDs']).isdisjoint(jb['requestIDs']),'Ordinary and MTP reused request IDs')
    require(ja['captureEvidence'] is True and jb['captureEvidence'] is False and config['captureEvidence'] is True,
            'Full numerical evidence was not independently admitted')
    prompt_raw=inputs.read(args.prompt_file,131072); prompt=parse_json(prompt_raw)
    require(digest(prompt_raw)==ja['promptFileSHA256']==jb['promptFileSHA256'] and len(prompt)==128
            and all(type(x) is int and 0<=x<262144 for x in prompt),'Exact shared prompt packet differs')
    require(ordinary['schema']=='gemma4_resident_benchmark_result_v1' and ordinary['job']==ja
            and mtp['schema']=='gemma4_local_mtp_cohort_result_v1' and mtp['benchmarkJob']==jb and mtp['configuration']==config,
            'Native ordinary/MTP report identity differs')
    require(config['benchmarkJobSHA256']==digest(inputs.read(args.mtp_case/'full.json',16384))
            and config['maximumDraftTokens'] in (1,2),'MTP original input/depth differs')
    require(ordinary['planSHA256']==mtp['planSHA256'],'Same source plan differs')
    all_requests=[]
    for job,value in ((ja,ordinary),(jb,mtp)):
        request_pins=[request_hash(job,i,prompt) for i in range(4)]; all_requests.append(request_pins)
        scope=ordinary_scope(job,value['planSHA256'],request_pins)
        require(value['scopeSHA256' if value is ordinary else 'ordinaryInputScopeSHA256']==scope,'Actual native request scope differs')
        require(value['nativeExecuted'] is True and value['modelReleased'] is True
                and value['nativeCacheBytesAfterRelease']==0 and value['collectiveCreated'] is False
                and value['collectiveReleased'] is False and value['warmupRequests']==1 and value['measuredRequests']==3
                and len(value['samples'])==4,'Actual native model/state retirement differs')
        require(value['sourceLoad']['selectedTensorCount']==1339 and value['sourceLoad']['sourceTensorCount']==1697,
                'Full registered source coverage differs')
    scope=text_hash(['gemma4-local-mtp-cohort-v1',config_sha,config['benchmarkJobSHA256'],mtp['ordinaryInputScopeSHA256'],
        mtp['assistantLoad']['artifactSHA256'],mtp['assistantLoad']['parameterLayoutSHA256'],
        'maximumDraftTokens='+str(config['maximumDraftTokens']),'captureEvidence=true',
        'qualifyConditioning='+str(operation=='qualify-mtp-conditioning-dense').lower(),'mtp=true','remote=false']+all_requests[1]+['targetProjection='+POLICY])
    require(mtp['scopeSHA256']==scope and mtp['assistantReleased'] is True and mtp['mtpEnabled'] is True
            and mtp['remoteAssistant'] is False,'MTP scope or assistant retirement differs')
    require(mtp['assistantLoad']['artifactSHA256']=='d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34'
            and mtp['assistantLoad']['configurationSHA256']=='0cd54ff36e53a258532c5c1433bc44b88ba758cfe9b59bb4e6eecfd5453fabcf'
            and mtp['assistantLoad']['tensorCount']==94 and mtp['assistantLoad']['allActualParametersReplaced'] is True,
            'Actual registered assistant identity differs')
    for key in ('artifactSHA256','configurationSHA256','parameterLayoutSHA256','planSHA256','loadedTensorBytes'):
        require(ordinary['sourceLoad'][key]==mtp['sourceLoad'][key],'Actual model source/layout differs: '+key)
    require(mtp['denseProjection']['policy']==POLICY and mtp['denseProjection']['expectedDenseModules']==235
        and mtp['denseProjection']['expectedTiedHeads']==1 and mtp['denseProjection']['serialHeadLogicalBytes']==4194304
        and mtp['denseProjection']['gatheredOverrideEnabled'] is False
        and mtp['denseProjection']['singleRowOverrideEnabled'] is False
        and mtp['denseProjection']['wholeModelNumericsQualified'] is False,'Actual dense target policy differs')
    for case in (args.ordinary_case,args.mtp_case):
        accepted=inputs.json(case/'comparison.json')
        require(accepted['status']=='passed' and accepted['nativeSHA256']==native['sha256']
            and accepted['packageSHA256']==digest(package_raw)
            and accepted['originalProcessRetired'] is True and accepted['sameEmptyLeaseInode'] is True,
            'Dense numerical replay requires both actual physical comparison receipts')
    sidecars=[Sidecars(inputs,pa,ordinary['files']),Sidecars(inputs,pb,mtp['files'])]
    total_bytes=0; width_counts=Counter(); accepted_counts=Counter(); summaries=[]
    for ordinal,(sa,sb) in enumerate(zip(ordinary['samples'],mtp['samples'])):
        ga=sa; gb=sb['generation']; ea=sa; eb=sb['evidence']
        for index,(sample,generation,job,requests) in enumerate(((sa,ga,ja,all_requests[0]),(sb,gb,jb,all_requests[1]))):
            require(sample['requestID']==job['requestIDs'][ordinal] and sample['requestStateRetired'] is True
                    and generation['requestSHA256']==requests[ordinal] and generation['ordinal']==ordinal
                    and generation['warmup'] is (ordinal==0) and generation['committedTokens']==143,
                    'Actual fresh request binding/frontier differs')
            tokens=generation['selectedTokenIDs']; require(len(tokens)==16 and all(type(x) is int and 0<=x<262144 for x in tokens),'Token bounds')
            require(sample['selectedTokenIDsSHA256']==digest(','.join(map(str,tokens)).encode()),'Actual selected-token hash differs')
            binding(sample['binding'],(ordinary,mtp)[index]['sourceLoad'])
        require(sb['scopeSHA256']==text_hash([scope,'iteration='+str(ordinal),all_requests[1][ordinal]]),'MTP per-request scope differs')
        require(ga['selectedTokenIDs']==gb['selectedTokenIDs'],'Greedy output differs at request '+str(ordinal))
        equal({k:v for k,v in sa['binding'].items() if k!='readAccountingSHA256'},
              {k:v for k,v in sb['binding'].items() if k!='readAccountingSHA256'},'Observed state/model layout differs')
        require(eb['capturedBeforeRequestRetirement'] is True and eb['outsideGenerationTiming'] is True,'MTP evidence lifecycle differs')
        require(row(ea['finalRow'],sidecars[0],ordinal,ga['selectedTokenIDs'][-1])
                ==row(eb['finalRow'],sidecars[1],ordinal,gb['selectedTokenIDs'][-1]),'Exact complete final native row differs')
        states=[state(e['finalState'],s['binding'],sc,ordinal) for e,s,sc in zip((ea,eb),(sa,sb),sidecars)]
        require(states[0]==states[1],'Exact chronological full90 native state differs at request '+str(ordinal))
        total_bytes+=sum(len(x[3]) for x in states[0].values())
        widths=gb['verificationWidths']; accepted=gb['acceptedPrefixes']
        require(len(widths)==len(accepted)==gb['verifiedWindows'] and widths and widths[0]==1
                and all(type(w) is int and 1<=w<=config['maximumDraftTokens']+1 for w in widths)
                and all(type(k) is int and 0<=k<w for k,w in zip(accepted,widths))
                and sum(accepted)+len(widths)==15 and gb['proposalTokens']==sum(w-1 for w in widths)
                and gb['acceptedProposalTokens']==sum(accepted) and gb['seedSteps']==widths.count(1),
                'Target verified-prefix accounting differs')
        width_counts.update(widths); accepted_counts.update(accepted)
        summaries.append(dict(ordinal=ordinal,warmup=ordinal==0,tokens=ga['selectedTokenIDs'],
                              finalStateSHA256=ea['finalState']['fingerprint'],verificationWidths=widths,acceptedPrefixes=accepted))
    require(any(w>1 for w in width_counts),'No actual rectangular target width exercised')
    for sc in sidecars: require(sc.used==set(sc.files),'Unjoined sidecar evidence')
    inputs.recheck()
    return dict(schema='gemma4_p128_local_mtp_numerical_comparison_v1',status='passed',
        nativeSHA256=native['sha256'],sourceSHA256=digest(source),buildReceiptSHA256=inputs.pins[str(args.build_receipt)]['sha256'],
        packageSHA256=digest(package_raw),promptFileSHA256=digest(prompt_raw),promptTokens=128,chunkTokens=64,outputTokens=16,
        requestsCompared=4,warmupRequests=1,measuredRequests=3,generatedTokensCompared=64,
        fullFinalRowsCompared=4,vocabularyValuesPerRow=262144,stateComponentsCompared=360,stateBytesCompared=total_bytes,
        nativeRowsAndStateExactlyEqual=True,actualObservedWidths=dict(width_counts),actualAcceptedPrefixLengths=dict(accepted_counts),
        samples=summaries,physical=[physical_a,physical_b],
        scope='same-build P128 final full rows, full90 states and all16 generated IDs for four actual requests',
        allIntermediateRowsCompared=False,allRollbackPrefixesQualified=False,longContextQualified=False,
        remoteExecutionQualified=False,performanceQualified=False,
        independentRootBuildInstallationAndAdmissionReviewStillRequired=True,retainedInputPins=list(inputs.pins.values()))


def main():
    parser=argparse.ArgumentParser(allow_abbrev=False)
    for name in ('ordinary-case','mtp-case','build-receipt','source-receipt','native-file','package-manifest','prompt-file','output'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    for path in vars(args).values(): require(path.is_absolute() and path.parent.resolve()==path.parent,'Canonical absolute paths required')
    require(not args.output.exists(),'Comparison output must be create-only')
    value=compare(args)
    with args.output.open('x') as stream: json.dump(value,stream,indent=2,allow_nan=False); stream.write('\n')
    print(json.dumps(dict(status='passed',output=str(args.output),fullRows=4,stateComponents=360)))


if __name__=='__main__': main()
