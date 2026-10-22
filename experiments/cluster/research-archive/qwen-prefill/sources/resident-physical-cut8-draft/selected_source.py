"""Pinned native catalog + independent registered tensor metadata; no model IO."""
import base64
import copy
import math
from pathlib import Path
import re

from binding_inputs import snapshot
from stage_checks.common import canonical, digest, exact, integer, parse, require, sha
from stage_checks.long_profile import ARTIFACT, CONFIGURATION

SELECTED_CUT = 8
PINS = {
    'selection/catalog.json': '906de56e50cde991a979743fb88b7db6bd8c93306a153a6af1fb761665cb75ee',
    'selection/canonical-names.json': 'e741488b0b0a32fa17a179b0e2a8744fca4fc55ca0814917ff49527207d6cb4f',
    'selection/retained-inputs.json': '1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25',
    'qualified-source-controls.json': '4be60341821c71b9c735bc87b8e0508576110f7bb9ddb2d9903a94acb15942fc',
    'qualified-source-audit.json': '41433a19217e35667f50be4404c4dc3a3d3c01fe07a6df0cb180aa885e84c9c7',
}
MANIFEST_SHA = '4f2735026cc7b40ee2c886ee53fb8755816c0001c4c69c141a61d5f56ff22aa4'
INVENTORY_SHA = '4a543a467846927736165c44a68802ad15794482ffdf3a1c60113a38c6abfb51'
DTYPE = {'U32':'uint32', 'F32':'float32', 'BF16':'bfloat16', 'F16':'float16'}
WIDTH = {'uint32':4, 'float32':4, 'bfloat16':2, 'float16':2}
LAYER = re.compile(r'(language_model\.model\.layers\.)(\d+)(\..+)')


def layout(rows, name, dtype):
    return digest('\n'.join(sorted(f'{r[name]}:{r[dtype]}:{r["shape"]}' for r in rows)).encode())


def inert_modules(rank):
    roles = [('language_model.lm_head', 'module-replacement', [1,4096],
              'Replace before parameter evaluation; stage 0 discards lazy logits'),
             ('language_model.model.norm', 'parameter-only-replacement', [4096],
              'Replace before parameter evaluation; stage 0 exports pre-final-norm hidden')] if rank == 0 else [
             ('language_model.model.embed_tokens', 'module-replacement', [1,4096],
              'Replace before parameter evaluation; incoming residual bypasses embedding; preserve checkpoint activation dtype')]
    return [dict(path=p, replacementKind=k, responsibility=r,
                 parameters=[dict(localName=p+'.weight',shape=s,dtype='bfloat16',byteCount=math.prod(s)*2)]) for p,k,s,r in roles]


def derive(catalog, retained, names, controls, cut):
    # Cut12 is accepted only by this pure recipe for the saved-control regression.
    # The production job and load() below are fixed to SELECTED_CUT.
    require(type(cut) is int and cut in (8,12), 'Unsupported selected metadata cut')
    exact(catalog['sourceConfigurationSHA256'], CONFIGURATION, 'Catalog configuration differs')
    require(catalog['kind']=='qwen_layer_stage_candidate_catalog' and catalog['metadataOnly'] is True
            and catalog['runtimeEligibilityEstablished'] is False, 'Catalog scope differs')
    configuration=base64.b64decode(retained['configuration'],validate=True)
    manifest_raw=base64.b64decode(retained['manifest'],validate=True);manifest=parse(manifest_raw)
    require(digest(configuration)==CONFIGURATION and digest(manifest_raw)==MANIFEST_SHA
            and manifest['aggregate_sha256']==ARTIFACT, 'Registered raw source identity differs')
    tensors=sorted(retained['canonicalTensors'],key=lambda r:r['name'])
    by={r['name']:r for r in tensors}
    require(len(by)==len(tensors)==927, 'Registered source is incomplete or duplicated')
    exact(sorted(names),sorted(by),'Catalog names differ from registered source')
    exact(catalog['canonicalNameCount'],927,'Catalog name count differs')
    exact(catalog['canonicalNamesSHA256'],digest(canonical(sorted(names))),'Catalog canonical names differ')
    inventory='\n'.join(f'{r["name"]}|{r["sourceDType"]}|{",".join(map(str,r["shape"]))}|{r["byteCount"]}' for r in tensors)
    require(digest(inventory.encode())==INVENTORY_SHA,'Registered canonical inventory differs')
    source=[]
    for row in tensors:
        shape=row['shape'];require(type(shape) is list and shape,'Missing tensor shape')
        for size in shape:integer(size,1)
        dtype=DTYPE[row['sourceDType']];integer(row['byteCount'],1)
        require(row['byteCount']==math.prod(shape)*WIDTH[dtype],'Tensor bytes differ from shape/dtype')
        source.append(dict(sourceName=row['name'],shape=shape,sourceDType=dtype,
            loadedDType='bfloat16' if dtype=='float16' else dtype,byteCount=row['byteCount']))
    source_by={r['sourceName']:r for r in source}
    candidates=[c for c in catalog['candidates'] if type(c['cut']) is int and c['cut']==cut]
    require(len(candidates)==1,'Selected native candidate is missing or duplicated');chosen=candidates[0]
    sha(chosen['planFingerprint']);exact(chosen['excludedCanonicalSourceNames'],[],'Unexpected source exclusions')
    stages=chosen['stages'];require(type(stages) is list and len(stages)==2,'Exactly two native stages required')
    active=[];summaries=[];states=[];seen=set()
    for rank,stage in enumerate(stages):
        start,end=((0,cut),(cut,32))[rank]
        exact(stage['stageIndex'],rank,'Stage order differs');exact(stage['sourceLayerRange'],[start,end],'Stage range differs')
        sha(stage['stageFingerprint']);sha(stage['constructionConfigurationSHA256'])
        wanted_state=[dict(layer=dict(globalIndex=i,localIndex=i-start,
            kind='full_attention' if (i+1)%4==0 else 'linear_attention'),
            components=['kv.keys','kv.values','kv.position_offsets'] if (i+1)%4==0 else ['conv','ssm']) for i in range(start,end)]
        exact(stage['state'],wanted_state,'Native state ownership differs');exact(stage['stateLayerCount'],end-start,'State layer count differs')
        states.append(wanted_state);rows=[];wanted_names=set()
        for name,record in source_by.items():
            match=LAYER.fullmatch(name)
            if match:
                layer=int(match[2]);require(0<=layer<32,'Source layer outside model')
                if not start<=layer<end:continue
                local=match[1]+str(layer-start)+match[3]
            else:
                require(name.startswith('language_model.model.embed_tokens.') or name.startswith('language_model.lm_head.')
                        or name=='language_model.model.norm.weight','Unknown source owner')
                if rank!=int(not name.startswith('language_model.model.embed_tokens.')):continue
                local=name
            rows.append(dict(record,localName=local));wanted_names.add(name)
        mappings=sorted(stage['parameters'],key=lambda r:r['localName'])
        rows.sort(key=lambda r:r['localName'])
        exact(mappings,[dict(sourceName=r['sourceName'],localName=r['localName'],stage=rank) for r in rows],
              'Native source/local parameter mapping differs')
        exact(stage['parameterCount'],len(rows),'Native parameter count differs')
        require(not seen.intersection(wanted_names),'Repeated stage source owner');seen.update(wanted_names)
        inert=inert_modules(rank);parameters=[p for m in inert for p in m['parameters']]
        exact(sorted(stage['inertModules'],key=lambda r:r['path']),
              sorted([dict(path=m['path'],responsibility=m['responsibility']) for m in inert],key=lambda r:r['path']),
              'Native inert responsibilities differ')
        roots=(['language_model.model.embed_tokens'] if rank==0 else ['language_model.model.norm','language_model.lm_head'])
        roots += ['language_model.model.layers.'+str(i) for i in range(end-start)]
        exact(stage['activeModuleRoots'],sorted(roots),'Native active roots differ')
        combined=[dict(name=r['localName'],dtype=r['loadedDType'],shape=r['shape']) for r in rows]
        combined += [dict(name=r['localName'],dtype=r['dtype'],shape=r['shape']) for r in parameters]
        summaries.append(dict(stageIndex=rank,constructionConfigurationSHA256=stage['constructionConfigurationSHA256'],
            stagePlanSHA256=stage['stageFingerprint'],activeMappingSHA256=digest(canonical(rows)),
            activeParameterLayoutSHA256=layout(rows,'localName','loadedDType'),parameterLayoutSHA256=layout(combined,'name','dtype'),
            loadedTensorBytes=sum(r['byteCount'] for r in rows),activeTensorCount=len(rows),
            inertTensorBytes=sum(p['byteCount'] for p in parameters),inertTensorCount=len(parameters)))
        active.append(rows)
    require(seen==set(by) and sum(len(r) for r in active)==927,'Stage source union differs')
    source_bytes=sum(r['byteCount'] for r in source);source_layout=layout(source,'sourceName','loadedDType')
    # Offsets are absent from the fixture. Carry only this cut-independent source
    # identity from the prior qualified artifact; do not claim offset replay.
    prior=controls['loads'];require(type(prior) is list and len(prior)==2,'Prior source pin missing')
    offset_manifest=sha(prior[0]['sourceTensorManifestSHA256'])
    for old in prior:
        for key,wanted in dict(verifiedAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION,
                sourceTensorManifestSHA256=offset_manifest,sourceParameterLayoutSHA256=source_layout,
                sourceModelTensorBytes=source_bytes).items():exact(old[key],wanted,'Qualified source '+key)
    commitment=dict(schemaVersion=1,verifiedAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION,
        planSHA256=chosen['planFingerprint'],sourceTensorManifestSHA256=offset_manifest,sourceModelTensorBytes=source_bytes,
        largestSourceTensorBytes=max(r['byteCount'] for r in source),sourceTensorCount=927,canonicalTensorCount=927,
        bf16ConversionEnabled=True,stages=summaries)
    loads=[]
    for rank,summary in enumerate(summaries):
        loads.append(dict(schemaVersion=1,stageIndex=rank,verifiedAggregateSHA256=ARTIFACT,sourceConfigurationSHA256=CONFIGURATION,
            constructionConfigurationSHA256=summary['constructionConfigurationSHA256'],planSHA256=chosen['planFingerprint'],
            stagePlanSHA256=summary['stagePlanSHA256'],sourceTensorManifestSHA256=offset_manifest,sourceParameterLayoutSHA256=source_layout,
            **{k:summary[k] for k in ('parameterLayoutSHA256','activeParameterLayoutSHA256','activeMappingSHA256','loadedTensorBytes','inertTensorBytes')},
            embeddingActivationDType='bfloat16',bf16ConversionEnabled=True,sourceModelTensorBytes=source_bytes,
            largestHostTensorBytes=max(r['byteCount'] for r in active[rank]),activeTensors=active[rank],inertModules=inert_modules(rank),
            storageCommitment=copy.deepcopy(commitment),storageCommitmentSHA256=digest(canonical(commitment))))
    return dict(cut=cut,ranges=[[0,cut],[cut,32]],states=states,planFingerprint=chosen['planFingerprint'],loads=loads)


def load():
    here=Path(__file__).parent;inputs={}
    for name,wanted in PINS.items():
        item=snapshot(here/name,4*1024**2);require(item['sha256']==wanted,'Selected source input pin differs: '+name)
        inputs[name]=parse(item['raw'])
    control=inputs['qualified-source-controls.json']
    require(control['cpuAuditSHA256']==PINS['qualified-source-audit.json']
            and inputs['qualified-source-audit.json']['status']=='passed','Prior source qualification differs')
    catalog=inputs['selection/catalog.json']
    exact(catalog['canonicalNamesRawSHA256'],PINS['selection/canonical-names.json'],'Catalog raw names pin differs')
    return derive(catalog,inputs['selection/retained-inputs.json']['nine'],inputs['selection/canonical-names.json'],control,SELECTED_CUT)
