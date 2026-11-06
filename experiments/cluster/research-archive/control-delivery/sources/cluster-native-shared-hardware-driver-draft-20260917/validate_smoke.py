"""Root-only local receipt join. No remote IO, model execution, or timing claim."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

PUBLIC_ID='f6a06d14-9138-4a19-aece-39207e1c874e'
INPUT='eeff23029fb833f9e6e7d466903038bb103ae3c4bb45981bc366987221324c07'
REQUEST='1645b9ddc580915dd8cbbafe245f82f773da1ceccc440766b4cebf247db19a12'
REFERENCE='8a808a8c2a065719442b2eb1a951b5f09dc03cfdb3250403e2a79b0a51d4ae4b'
ROLES={'coordinatorConfig','leaderConfig','coordinatorResult','reserved','leaderResult','description'}

def require(ok,message):
    if not ok: raise ValueError(message)

def decode(data):
    def object_pairs(pairs):
        out={}
        for key,value in pairs:
            require(key not in out,'duplicate JSON key')
            out[key]=value
        return out
    def invalid_constant(value):raise ValueError('nonfinite JSON value')
    return json.loads(data,object_pairs_hook=object_pairs,parse_constant=invalid_constant)

def boolean_pair(value,expected):
    return isinstance(value,list) and len(value)==2 and all(x is expected for x in value)

def read(row):
    require(set(row)=={'path','sha256'},'exact path/hash role required')
    path=Path(row['path']);require(path.is_absolute() and path.resolve()==path,'canonical role path')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd);require(stat.S_ISREG(before.st_mode) and before.st_size<=65536,'bounded regular role')
        parts=[];total=0
        while True:
            b=os.read(fd,65537-total)
            if not b: break
            parts.append(b);total+=len(b);require(total<=65536,'role exceeds bound')
        data=b''.join(parts);after=os.fstat(fd)
        require((before.st_dev,before.st_ino,before.st_size)==(after.st_dev,after.st_ino,after.st_size) and len(data)==after.st_size,'role changed')
    finally:os.close(fd)
    require(hashlib.sha256(data).hexdigest()==row['sha256'],'role hash mismatch')
    return decode(data),data

def check(packet):
    require(set(packet)==ROLES,'six exact roles required')
    roles={k:read(v) for k,v in packet.items()}
    c=roles['coordinatorConfig'][0];l=roles['leaderConfig'][0]
    cr=roles['coordinatorResult'][0];reserved=roles['reserved'][0];result=roles['leaderResult'][0];desc=roles['description'][0]
    require(c['schema']=='native_shared_hardware_coordinator_v1' and l['schema']=='native_shared_hardware_leader_v1','configuration schema')
    require(cr['schema']=='native_shared_hardware_coordinator_result_v1' and cr['success'] is True and cr['error']=='','coordinator terminal')
    require(cr['configSHA256']==packet['coordinatorConfig']['sha256'],'coordinator configuration join')
    require(reserved['schema']==result['schema']=='native_shared_hardware_leader_result_v1','leader schema')
    extras={'tokenIDs','requestRetired','bytesInUseAfterRelease','retainedOwnerShutdownReturned','success'}
    require(set(result)==set(reserved)|extras and all(result[k]==v for k,v in reserved.items()),'reserved-to-terminal inverse')
    require(result['publicRequestID']==PUBLIC_ID and type(result['cbv2RequestID']) is int and result['cbv2RequestID']==1,'public ID join')
    native_id=uuid.UUID(result['nativeRequestID']);require(native_id.version==4 and str(native_id)==result['nativeRequestID'],'actual inner UUID format')
    require(result['configurationFileSHA256']==packet['leaderConfig']['sha256'],'leader configuration join')
    require(result['inputBindingSHA256']==INPUT and result['requestSHA256']==REQUEST and result['referenceSHA256']==REFERENCE,'fixed original reference/input')
    require(result['tokenIDs']==[1654,421] and result['requestRetired'] is True and type(result['bytesInUseAfterRelease']) is int and result['bytesInUseAfterRelease']==0 and result['retainedOwnerShutdownReturned'] is True and result['success'] is True,'complete token/retirement smoke')
    require(result['hardwareSmokeOnly'] is True and result['numericallyQualified'] is False,'no numerical qualification from tokens')
    require(type(result['reservedBytes']) is int and type(result['readyCapacityBytes']) is int and 0<result['reservedBytes']<=result['readyCapacityBytes'],'actual named resource reservation')
    for key in ('tlsConfigurationSHA256','nativeSHA256','cliSHA256','descriptorSHA256','capabilitySHA256','resourcePolicySHA256','planSHA256','configurationSHA256','nativePeerIDs'):
        require(result[key]==l[key],f'leader {key} bind')
    obs=cr['observation'];approval=c['approval']
    require(uuid.UUID(result['membershipEpoch']).hex==obs['epoch'],'actual epoch join')
    require(obs['devices']==c['devices'] and len(set(obs['providerIDs']))==2,'ordered actual hardware/Provider IDs')
    require(obs['providerBinarySHA256']==[l['cliSHA256']]*2,'actual approved private CLI builds')
    require(obs['nativeSHA256']==l['nativeSHA256'] and obs['planSHA256']==l['planSHA256'] and obs['approvalID']==approval['ID'],'selected actual runtime')
    require(obs['phase']=='released' and boolean_pair(obs['released'],True) and obs['committed'] is True and boolean_pair(obs['keyConfirmed'],True) and type(obs['meshRound']) is int and obs['meshRound']==4 and boolean_pair(obs['workerReady'],True),'actual trust/mesh/release phases')
    require(all(obs[k] is True for k in ('relayWritersEnded','cancellationPublished','aggregatePublicationEnded')) and boolean_pair(obs['aggregatePublicationFailed'],False),'actual publication outcome')
    require(len(set(obs['startSHA256']))==2 and all(len(x)==64 for x in obs['startSHA256']),'two original owner starts')
    require(len(obs['workerRecords'])==len(obs['workerBytes'])==2 and all(type(x) is int and 0<x<=128 for x in obs['workerRecords']) and all(type(x) is int and 0<x<=2*1024*1024 for x in obs['workerBytes']),'bounded actual worker relay')
    require(packet['description']['sha256']==l['descriptorSHA256'],'actual raw description join')
    require(desc['schema']=='qwen9b_protected_runtime_description_v1' and desc['staticProfile']=='qwen9b_short_records_experiment_v1' and desc['bootstrapProfile']=='native_key_prelude_mesh2_v1','protected descriptor scope')
    require((desc['stageCut'],desc['promptTokens'],desc['chunkTokens'],desc['outputTokens'],desc['prefillSchedule'],desc['stopTokenIDs'])==(16,32,16,2,'serial_v1',[]),'workload unchanged')
    for field,key,policy in [('runtimeBinarySHA256','nativeSHA256','NativeRuntimeSHA256'),('selectedPlanSHA256','planSHA256','PlanSHA256'),('capabilitySHA256','capabilitySHA256','CapabilitySHA256'),('resourcePolicySHA256','resourcePolicySHA256','ResourcePolicySHA256')]:
        require(desc[field]==l[key]==bytes(approval[policy]).hex(),f'description/catalog {field}')
    for field,sha in [('ordinaryCapabilityBase64',l['capabilitySHA256']),('resourcePolicyBase64',l['resourcePolicySHA256'])]:
        raw=base64.b64decode(desc[field],validate=True);require(base64.b64encode(raw).decode()==desc[field] and hashlib.sha256(raw).hexdigest()==sha,'canonical actual nested metadata')
    return {'schema':'native_shared_hardware_smoke_join_v1','success':True,'nativeRequestID':str(native_id),
            'membershipEpoch':result['membershipEpoch'],'publicRequestID':PUBLIC_ID,'cbv2RequestID':1,
            'rankBuildSHA256':[l['nativeSHA256']]*2,'resourcePolicySHA256':l['resourcePolicySHA256'],
            'tokenIDs':[1654,421],'numericallyQualified':False,'physicalPostflightValidated':False,
            'requiredSeparateEvidence':['both native and member process/group fences','same empty canonical journals','resource/AC/zero-swap/pressure replay','restored temporary aliases','full logits/state comparison for numerical qualification'],
            'inputs':packet}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('packet',type=Path);parser.add_argument('output',type=Path);parser.add_argument('--numerical-join',type=Path);args=parser.parse_args()
    require(args.packet.is_absolute() and args.packet.resolve()==args.packet,'canonical packet path')
    fd=os.open(args.packet,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        info=os.fstat(fd);require(stat.S_ISREG(info.st_mode) and info.st_size<=16384,'bounded regular packet')
        raw=os.read(fd,16385);require(len(raw)==info.st_size and len(raw)<=16384,'packet bound or identity changed')
    finally:os.close(fd)
    result=check(decode(raw))
    with args.output.open('x') as f:json.dump(result,f,sort_keys=True,indent=2);f.write('\n')
    if args.numerical_join:
        join={key:result[key] for key in ('publicRequestID','nativeRequestID','membershipEpoch','rankBuildSHA256','resourcePolicySHA256')}
        with args.numerical_join.open('x') as f:json.dump(join,f,sort_keys=True,separators=(',',':'));f.write('\n')
