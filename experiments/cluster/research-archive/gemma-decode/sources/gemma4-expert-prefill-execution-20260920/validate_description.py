"""Check saved actual metadata output; never executes a product or reads a model."""
import argparse
import hashlib
import json
from pathlib import Path
from build_binding import read, verify
from package.expert_results import scope
from package.binding_common import require, same
from package.gemma_inputs import validate_job


def validate(job, value, bindings):
    validate_job(dict(schema='gemma4_expert_physical_job_v1',kind='rdma',mode='stage'+str(job['rank']),
        layer=job['layer'],modelDirectory=job['modelDirectory'],nativeSHA256=job['buildIdentitySHA256'],
        timeoutSeconds=job['timeoutSeconds'],nativeJob=job))
    product=next(x for x in bindings['products'] if x['product']=='GemmaExpertRDMACheck')
    require(job['buildIdentitySHA256']==product['sha256'],'Description must name actual newly bound RDMA binary')
    expected=dict(schema='gemma4_expert_rdma_capability_v1',scopeSHA256=scope(job),
        rank=job['rank'],globalLayerIndex=job['layer'],
        globalExpertIDsByRank=[list(range(48)),list(range(48,128))] if job['ownership']=='contiguous48_80'
            else [[x for x in range(128) if x%3==0],[x for x in range(128) if x%3!=0]],
        tokenCounts=job['tokenCounts'],topK=8,hiddenSize=2816,intermediateSize=704,dtype='bfloat16',
        maximumAssignments=1024,maximumControlBytes=32768,maximumTensorBytes=8388608,
        maximumRecordsPerDirection=128,extraNativeStagingBytes=33554432,extraHostStagingBytes=33554432,
        minimumActualFreeBytes=6*1024**3,requiresAC=True,requiredPressureLevel=1,maximumSwapBytes=0,
        metadataOnly=True,nativeExecuted=False,sourcePayloadVerified=False,
        deviceOnlyDynamicRoutingQualified=False,encryptedRDMA=False,runtimeServingEnabled=False,
        buildIdentityRequiresParentVerification=True)
    same(value,expected,'Exact enlarged native description')


if __name__=='__main__':
    parser=argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('native_job');parser.add_argument('actual_stdout')
    args=parser.parse_args()
    job,jpin=read(Path(args.native_job).absolute())
    value,vpin=read(Path(args.actual_stdout).absolute())
    bindings=verify();validate(job,value,bindings)
    print(json.dumps(dict(metadataValuesMatched=True,job=jpin,actualOutput=vpin,
        artifactBindingsSHA256=hashlib.sha256((Path(__file__).parent/'artifact-bindings.json').read_bytes()).hexdigest(),
        executionProvenByThisParser=False,nativeExecutedByThisParser=False),sort_keys=True))
