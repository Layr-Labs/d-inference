"""After root build/describe only: prepare small bound inputs and a deployment map."""
import argparse
import json
import os
from pathlib import Path
import sys
sys.dont_write_bytecode=True
BASE=Path(__file__).resolve().parent
sys.path[:0]=[str(BASE/'package'),str(BASE/'comparison')]
from binding_common import canonical, fields, parse, require, same, sha
from binding_inputs import snapshot
from gemma_inputs import REMOTE, PRODUCT, MODEL, SOURCE_DRIVER, SOURCE_COMPARATOR, METALLIB, PAGED, write_json, write_new
from contract import expected_description


def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--inputs',required=True,type=Path)
    p.add_argument('--inputs-sha256',required=True);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    require(a.output.is_absolute() and a.output.parent.resolve()==a.output.parent,'Canonical new output parent')
    raw=snapshot(a.inputs,65536);same(raw['sha256'],a.inputs_sha256,'Root input packet')
    packet=parse(raw['raw']);fields(packet,'schema buildReceipt sourceSnapshot dependencySnapshot describeReceipt expected prompt promptReceipt jobTemplate metadataDirectory','root inputs')
    same(packet['schema'],'gemma_short_root_build_inputs_v1','input schema')
    loaded={}
    for name in ('buildReceipt','sourceSnapshot','dependencySnapshot','describeReceipt','expected','prompt','promptReceipt','jobTemplate'):
        ref=fields(packet[name],'path sha256',name);item=snapshot(Path(ref['path']),4*1024**2)
        same(item['sha256'],ref['sha256'],name);loaded[name]=item
    build=parse(loaded['buildReceipt']['raw']);expected=parse(loaded['expected']['raw']);job=parse(loaded['jobTemplate']['raw'])
    actual_build=parse((BASE/'package/native-build-reference.json').read_bytes())
    same(loaded['buildReceipt']['sha256'],actual_build['buildReceiptSHA256'],'Exact root-qualified build receipt')
    same(build['binary']['sha256'],actual_build['nativeSHA256'],'Exact root-qualified native')
    same(build['binary']['bytes'],actual_build['nativeBytes'],'Exact native size')
    for key in ('sourceSnapshotSHA256','dependencySnapshotSHA256'):same(build[key],actual_build[key],'Exact qualified '+key)
    expected_description(expected,loaded['prompt']['raw'])
    tokenized=parse(loaded['promptReceipt']['raw'])
    same(tokenized['schema'],'gemma_short_tokenizer_packet_v1','Physical prompt provenance')
    same(tokenized['generatorSHA256'],sha((BASE/'prepare_prompt.py').read_bytes()),'Tokenizer helper source')
    same(tokenized['promptFileSHA256'],loaded['prompt']['sha256'],'Tokenizer packet pin')
    same(tokenized['tokenIDs'],parse(loaded['prompt']['raw']),'Tokenizer packet IDs')
    same(tokenized['tokenIDs'],tokenized['allTokenIDs'][:32],'Tokenizer first32 selection')
    require(tokenized['selection']=='first_32_tokenizer_ids' and tokenized['chatTemplateApplied'] is False
        and tokenized['addSpecialTokens'] is True and tokenized['modelOrGPUExecuted'] is False,'Tokenizer provenance scope')
    same(build['status'],'passed','Actual native build required');same(build['before'],build['after'],'Build input stability')
    same(build['sourceSnapshotSHA256'],loaded['sourceSnapshot']['sha256'],'Build sources')
    same(build['dependencySnapshotSHA256'],loaded['dependencySnapshot']['sha256'],'Build dependencies')
    require(build['nativeModelExecuted'] is False and build['remoteExecuted'] is False,'Build-only ancestry')
    require(len(build['steps'])==5 and all(x['exitCode']==0 and x['reaped'] and x['groupAbsent'] for x in build['steps']),'Five actual completed build/check steps')
    native=build['binary'];same(Path(native['path']).name,PRODUCT,'Product')
    same([Path(x['argv'][0]).name for x in build['steps']],['swift','xcrun',PRODUCT,PRODUCT,PRODUCT],'Exact five build/check roles')
    same(build['steps'][2]['argv'],[native['path'],'--check-attention-identity','cpu'],'Actual identity control argv')
    same(build['steps'][3]['argv'][1],'--check-local-fixtures','Existing local controls')
    same(build['steps'][4]['argv'][1],'--check-arguments','Existing argument controls')
    same(expected['buildIdentitySHA256'],native['sha256'],'Expected actual binary')
    describe=parse(loaded['describeReceipt']['raw'])
    same(describe['argv'],[native['path'],'--describe',packet['jobTemplate']['path']],'Actual prospective describe argv')
    require(describe['exitCode']==0 and describe['reaped'] and describe['groupAbsent'],'Describe did not complete')
    describe_path=Path(packet['describeReceipt']['path'])
    same(Path(packet['expected']['path']),describe_path.with_suffix('.stdout'),'Retained describe stdout binding')
    require(describe_path.with_suffix('.stderr').read_bytes()==b'','Describe stderr')
    fields(job,'schema mode modelDirectory metadataDirectory promptFile promptFileSHA256 outputDirectory requestID membershipEpoch buildIdentitySHA256 residualDType timeoutSeconds','job')
    same(job['schema'],'gemma4_short_native_check_v1','job schema');same(job['mode'],'full','first mode')
    same(job['metadataDirectory'],packet['metadataDirectory'],'Described local metadata')
    same(job['promptFile'],packet['prompt']['path'],'Described local prompt');same(job['timeoutSeconds'],300,'native deadline')
    for name in ('requestID','membershipEpoch','buildIdentitySHA256','promptFileSHA256'):same(job[name],expected[name],name)
    same(job['residualDType'],expected['profile']['activationDType'],'Residual dtype')
    model=Path(job['modelDirectory']);same(str(model),MODEL,'Exact root-selected model path')
    sources={}
    def add(name,path,size=None,digest=None):
        path=Path(path);require(name not in sources,'Repeated deployment member')
        if size is None:
            item=snapshot(path,4*1024**2,keep=False,empty=True);size=item['size_bytes'];digest=item['sha256']
        sources[name]=dict(path=str(path),bytes=size,sha256=digest,mode=0o700 if name=='bundle/'+PRODUCT else 0o600)
    a.output.mkdir(mode=0o700);os.umask(0o077)
    remote_job=dict(job,metadataDirectory=str(REMOTE/'metadata'),promptFile=str(REMOTE/'prompt.ids.json'),
                    outputDirectory=str(REMOTE/'runs/full-1/sidecars'))
    write_json(a.output/'job-template.json',remote_job)
    for path in sorted((BASE/'package').rglob('*')):
        if path.is_file():add(path.relative_to(BASE/'package').as_posix(),path)
    binding=dict(schema='gemma_short_deployment_binding_v1',driverManifestSHA256=SOURCE_DRIVER,
        comparatorManifestSHA256=SOURCE_COMPARATOR,nativeSHA256=native['sha256'],sourceSnapshotSHA256=loaded['sourceSnapshot']['sha256'],
        dependencySnapshotSHA256=loaded['dependencySnapshot']['sha256'],buildReceiptSHA256=loaded['buildReceipt']['sha256'],
        expectedSHA256=loaded['expected']['sha256'],promptSHA256=loaded['prompt']['sha256'],residualDType=job['residualDType'],modelDirectory=str(model))
    write_json(a.output/'binding.json',binding);add('binding.json',a.output/'binding.json')
    add('job-template.json',a.output/'job-template.json')
    for name,dest in [('expected','expected.json'),('prompt','prompt.ids.json'),('promptReceipt','provenance/prompt-receipt.json'),('jobTemplate','provenance/described-job.json'),
        ('buildReceipt','provenance/build-receipt.json'),('sourceSnapshot','provenance/source-snapshot.json'),
        ('dependencySnapshot','provenance/dependency-snapshot.json'),('describeReceipt','provenance/describe-receipt.json')]:
        add(dest,packet[name]['path'])
    metadata=Path(packet['metadataDirectory']);require(metadata.is_absolute() and metadata.resolve()==metadata,'Metadata path')
    controls=parse((BASE/'metadata-controls.json').read_bytes())
    for row in controls:
        item=snapshot(metadata/row['path'],2*1024**2,keep=False)
        same(item['sha256'],row['sha256'],'Pinned captured metadata');same(item['size_bytes'],row['bytes'],'Metadata size')
        add('metadata/'+row['path'],metadata/row['path'],row['bytes'],row['sha256'])
    model_manifest=parse((metadata/'manifest.json').read_bytes())
    same(tokenized['manifestSHA256'],sha((metadata/'manifest.json').read_bytes()),'Tokenizer manifest identity')
    same(tokenized['artifactSHA256'],model_manifest['aggregate_sha256'],'Tokenizer artifact')
    tokenizer_row=next(r for r in model_manifest['files'] if r['path']=='tokenizer.json')
    same(tokenized['tokenizerSHA256'],tokenizer_row['sha256'],'Registered tokenizer')
    same(tokenized['tokenizerBytes'],tokenizer_row['size_bytes'],'Registered tokenizer size')
    add('bundle/'+PRODUCT,native['path'],native['bytes'],native['sha256'])
    expected_resources={'mlx.metallib':METALLIB,'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal':PAGED}
    require(len(build['resources'])==2,'Native resource closure')
    for resource in build['resources']:
        relative=Path(resource['path']).relative_to(Path(native['path']).parent).as_posix()
        same(resource['sha256'],expected_resources.pop(relative),'Native resource binding')
        add('bundle/'+relative,resource['path'],resource['bytes'],resource['sha256'])
    require(not expected_resources,'Missing resource')
    package=dict(schema='gemma_short_package_v1',files=[{k:v for k,v in dict(path=n,**{k:v for k,v in r.items() if k!='path'}).items() if k!='mode'} for n,r in sorted(sources.items())])
    write_json(a.output/'package.json',package);add('package.json',a.output/'package.json')
    deployment=dict(schema='gemma_short_copy_only_tree_v1',files={'check/'+n:{k:r[k] for k in ('bytes','sha256','mode')} for n,r in sources.items()})
    write_json(a.output/'deployment.json',deployment);write_json(a.output/'sources.json',sources)
    write_json(a.output/'binding-receipt.json',dict(inputPacketSHA256=a.inputs_sha256,packageSHA256=sha(canonical(package)+b'\n'),
        deploymentSHA256=sha(canonical(deployment)+b'\n'),binding=binding,nativePayloadRehashed=False,
        modelCopied=False,modelExecuted=False,remoteExecuted=False,readyForRootCopyReview=True))
    print(canonical(dict(output=str(a.output),packageSHA256=sha(canonical(package)+b'\n'))).decode())


if __name__=='__main__':main()
