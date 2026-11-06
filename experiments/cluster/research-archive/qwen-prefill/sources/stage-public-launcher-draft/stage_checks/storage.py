"""Generic source ownership and compact stage storage commitment consistency."""
import re
from .common import canonical,digest,exact,integer,require,sha,shape_bytes


def layout(entries,name='localName',dtype='loadedDType'):
    return digest('\n'.join(sorted(f"{x[name]}:{x[dtype]}:{x['shape']}" for x in entries)).encode())


def validate_pair(loads,context):
    text=context['text'];layers=text['num_hidden_layers'];half=layers//2
    namespace='language_model.' if context['configuration']['model_type']=='qwen3_5' else ''
    common=loads[0]['storageCommitment'];all_active=[];seen=set();summaries=[]
    require(integer(common['schemaVersion'])==1,'Unsupported stage storage commitment schema')
    for rank,receipt in enumerate(loads):
        require(integer(receipt['schemaVersion'])==1 and integer(receipt['stageIndex'])==rank,'Stage source schema/index differs')
        require(receipt['verifiedAggregateSHA256']==context['artifact'] and receipt['sourceConfigurationSHA256']==context['configuration_sha256'],'Stage artifact/config pin differs')
        require(receipt['bf16ConversionEnabled']is True,'Changed source conversion policy')
        for key in ('planSHA256','stagePlanSHA256','sourceTensorManifestSHA256','sourceParameterLayoutSHA256',
                    'constructionConfigurationSHA256','parameterLayoutSHA256','activeParameterLayoutSHA256',
                    'activeMappingSHA256','storageCommitmentSHA256'):sha(receipt[key])
        active=receipt['activeTensors'];require(isinstance(active,list) and 0<len(active)<=100000,'Unbounded active inventory')
        require(active==sorted(active,key=lambda x:x['localName']),'Active mappings must be ordered')
        local=set()
        for tensor in active:
            require(set(tensor)=={'sourceName','localName','shape','sourceDType','loadedDType','byteCount'},'Active tensor schema differs')
            name=tensor['sourceName'];require(type(name)is str and name not in seen,'Duplicate source tensor owner');seen.add(name)
            match=re.fullmatch(re.escape(namespace)+r'model\.layers\.(\d+)\.(.+)',name)
            if match:
                layer=int(match[1]);require(rank*half<=layer<(rank+1)*half,'Source layer assigned to wrong stage')
                mapped=namespace+f'model.layers.{layer-rank*half}.'+match[2]
            else:
                roots=[namespace+'model.embed_tokens.'] if rank==0 else [namespace+'lm_head.',namespace+'model.norm.']
                allowed={root+suffix for root in roots for suffix in ('weight','scales','biases') if not root.endswith('model.norm.') or suffix=='weight'}
                require(name in allowed,'Unsupported non-layer source owner');mapped=name
            require(tensor['localName']==mapped and mapped not in local,'Invalid/colliding compact tensor name');local.add(mapped)
            require(tensor['sourceDType']in('uint32','float16','bfloat16','float32'),'Unsupported source dtype')
            loaded='bfloat16' if tensor['sourceDType']=='float16' else tensor['sourceDType']
            require(tensor['loadedDType']==loaded,'Source conversion differs')
            require(integer(tensor['byteCount'])==shape_bytes(tensor['shape'],loaded),'Active tensor byte count differs')
            all_active.append(dict(tensor,localName=name))
        require(digest(canonical(active))==receipt['activeMappingSHA256'] and layout(active)==receipt['activeParameterLayoutSHA256'],'Active tensor commitments differ')
        inert=[]
        expected_inert={namespace+'model.norm':([text['hidden_size']],'parameter-only-replacement'),namespace+'lm_head':([1,text['hidden_size']],'module-replacement')} if rank==0 else {namespace+'model.embed_tokens':([1,text['hidden_size']],'module-replacement')}
        require(len(receipt['inertModules'])==len(expected_inert) and {m['path'] for m in receipt['inertModules']}==set(expected_inert),'Inert module namespace differs')
        for module in receipt['inertModules']:
            expected_shape,expected_kind=expected_inert[module['path']]
            require(module['replacementKind']==expected_kind and len(module['parameters'])==1,'Inert replacement responsibility differs')
            only=module['parameters'][0]
            require(only['localName']==module['path']+'.weight' and only['dtype']==receipt['embeddingActivationDType'],'Inert parameter identity/dtype differs')
            exact(only['shape'],expected_shape,'Inert parameter shape differs')
            require(module['replacementKind']in('module-replacement','parameter-only-replacement'),'Unknown inert replacement')
            for tensor in module['parameters']:
                require(tensor['localName']not in local,'Active/inert collision');local.add(tensor['localName'])
                require(integer(tensor['byteCount'])==shape_bytes(tensor['shape'],tensor['dtype']),'Inert tensor byte count differs')
                inert.append(dict(tensor,loadedDType=tensor['dtype']))
        require(layout(active+inert)==receipt['parameterLayoutSHA256'],'Complete stage layout differs')
        require(integer(receipt['loadedTensorBytes'])==sum(x['byteCount'] for x in active),'Active bytes differ')
        require(integer(receipt['inertTensorBytes'])==sum(x['byteCount'] for x in inert),'Inert bytes differ')
        integer(receipt['largestHostTensorBytes'],1,512*1024**2)
        exact(receipt['storageCommitment'],common,'Stage common storage commitment differs')
        for key in ('verifiedAggregateSHA256','sourceConfigurationSHA256','planSHA256','sourceTensorManifestSHA256','sourceModelTensorBytes','bf16ConversionEnabled'):
            exact(receipt[key],common[key],'Local/common source metadata differs: '+key)
        require(digest(canonical(common))==receipt['storageCommitmentSHA256'],'Storage commitment hash differs')
        summary={key:receipt[key] for key in ('stageIndex','constructionConfigurationSHA256','stagePlanSHA256',
            'activeMappingSHA256','activeParameterLayoutSHA256','parameterLayoutSHA256','loadedTensorBytes','inertTensorBytes')}
        summary.update(activeTensorCount=len(active),inertTensorCount=len(inert));summaries.append(summary)
    require(sum(x['byteCount'] for x in all_active)==integer(common['sourceModelTensorBytes'],1,6*1024**3),'Source byte conservation differs')
    require(integer(common['canonicalTensorCount'])==len(all_active),'Canonical tensor count differs')
    require(layout(all_active)==loads[0]['sourceParameterLayoutSHA256']==loads[1]['sourceParameterLayoutSHA256'],'Complete source layout differs')
    for key in ('verifiedAggregateSHA256','sourceConfigurationSHA256','planSHA256','sourceTensorManifestSHA256',
                'sourceModelTensorBytes','bf16ConversionEnabled'):
        exact(common[key],loads[0][key],'Source commitment identity differs: '+key)
    integer(common['sourceTensorCount'],1,100000);integer(common['largestSourceTensorBytes'],1,512*1024**2)
    exact(common['stages'],summaries,'Ordered storage stage summaries differ')
    return dict(canonical_tensor_count=len(all_active),source_bytes=common['sourceModelTensorBytes'],
                selected_bytes=[x['loadedTensorBytes'] for x in loads],source_descriptor_payloads_rederived=False)
