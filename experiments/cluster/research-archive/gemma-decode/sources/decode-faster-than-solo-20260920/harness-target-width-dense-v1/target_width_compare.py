"""All24 rows/360 native state files; exact equality, no tolerance or model work."""
import hashlib
import math
from pathlib import Path
import struct
from recorded_math import WIDTH,canonical,digest,equal,logical_bytes,parse_json,require,sha_string
from snapshot import snapshot
from target_width_binding import binding,finite,integer,ordinary_scope,request_hash,text_hash
from target_width_contract import MODES,ROW_ORDINALS,POLICY,validate_result

HELPERS={'recorded_math.py':'f166a6a27c20021c30c62e6966e63583b9ecab955a3b23af64869cd821f25914',
         'snapshot.py':'46dfa5689fba4358412c6c4ce03a759ca71d5c30bcde9df995a46c4aad97873b'}
ROOT=Path(__file__).resolve().parent
COMPONENTS=('kv.keys','kv.position_offsets','kv.values')

class Files:
    def __init__(self,root,records):
        self.root=root;self.records={x['name']:x for x in records};self.used=set();self.pins=[]
        require(root.is_absolute() and root.resolve()==root and len(self.records)==len(records)==384,
                'Width evidence directory/cardinality')
        require(set(x.name for x in root.iterdir())==set(self.records),'Missing/extra width sidecars')
    def read(self,record):
        require(self.records.get(record['name'])==record and record['name'] not in self.used,'Substituted/repeated width file')
        p=self.root/record['name'];require(p.lstat().st_nlink==1,'Width sidecar has extra hard link')
        value=snapshot(p,16*1024**2,keep=True)
        require(value['size_bytes']==record['bytes'] and value['sha256']==record['sha256'],'Width sidecar hash/size')
        self.used.add(record['name']);self.pins.append(dict(path=str(p),bytes=value['size_bytes'],sha256=value['sha256'],identity=list(value['identity'])))
        return value['raw']
    def finish(self):
        require(self.used==set(self.records),'Unjoined width sidecars')
        for row in self.pins:
            s=Path(row['path']).lstat()
            require(list((s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns))==row['identity'],
                    'Width retained file changed during comparison')

def native_state(sample,files):
    state=sample['checkpointState'];bind=sample['binding'];ordinal=sample['ordinal']
    require(set(state)=={'frontier','fingerprint','entries'} and state['frontier']==132 and len(state['entries'])==90,
            'Width exact checkpoint132')
    identities=[]
    for entry,(layer,component) in zip(state['entries'],[(i,c) for i in range(30) for c in COMPONENTS]):
        require(set(entry)=={'localLayerIndex','globalLayerIndex','component','dtype','sha256','shape','byteCount','logicalRange','file'},
                'Width native state fields')
        require((entry['localLayerIndex'],entry['globalLayerIndex'],entry['component'])==(layer,layer,component),
                'Width complete native state domain/order')
        geometry=bind['layers'][layer];position=component=='kv.position_offsets'
        dtype='int32' if position else geometry['dtype']
        shape=[1] if position else [1,geometry['kvHeads'],132,geometry['headDimension']]
        count=math.prod(shape)*WIDTH[dtype];logical=[] if position else [0,132]
        equal([entry['dtype'],entry['shape'],entry['byteCount'],entry['logicalRange']],
              [dtype,shape,count,logical],'Width native temporal shape/dtype')
        equal(entry['file'],dict(name=f'request-{ordinal}-width-{MODES[ordinal].lower()}-state-{layer}-{component}.bin',
              bytes=count,sha256=entry['sha256']),'Width native state filename/hash')
        raw=files.read(entry['file']);require(digest(raw)==sha_string(entry['sha256']),'Width state logical hash')
        if position:require(raw==struct.pack('<i',132),'Width actual position132')
        else:finite(raw,dtype)
        identity=f"{layer}|{component}|{shape}|{dtype}|{count}|{entry['sha256']}"
        if not position:identity+='|range=0:132'
        identities.append(identity)
        yield (layer,component),(dtype,shape,logical,raw)
    require(state['fingerprint']==text_hash(['cbv2-owned-attention-state-v2',bind['stateLayoutSHA256'],'tokens=132']+identities),
            'Width whole-state fingerprint')

def mismatch(a,b,dtype):
    require(len(a)==len(b),'Width native byte count differs')
    unit=WIDTH[dtype];count=len(a)//unit
    if a==b:return dict(exact=True,differentNativeElements=0,firstDifferentElement=None)
    bits='H' if unit==2 else 'I'
    words_a=memoryview(a).cast(bits);words_b=memoryview(b).cast(bits)
    different=0;first=None
    for i,(x,y) in enumerate(zip(words_a,words_b)):
        if x!=y:
            different+=1
            if first is None:first=i
    return dict(exact=False,differentNativeElements=different,firstDifferentElement=first)

def compare_sidecars(returned,result,job):
    validate_result(result,job)
    for name,wanted in HELPERS.items():require(digest((ROOT/name).read_bytes())==wanted,'Frozen numerical helper changed')
    prompt_path=ROOT/'deployment/prompts/prompt-128.json'
    prompt_snapshot=snapshot(prompt_path,131072,keep=True)
    require(prompt_snapshot['sha256']==job['promptFileSHA256'],'Width exact prompt hash')
    prompt=parse_json(prompt_snapshot['raw'])
    require(len(prompt)==128 and all(type(x) is int and 0<=x<262144 for x in prompt),'Width exact prompt IDs')
    hashes=[request_hash(job,i,prompt) for i in range(4)]
    require(result['ordinaryInputScopeSHA256']==ordinary_scope(job,result['planSHA256'],hashes),'Width original input scope')
    files=Files(returned/'sidecars',result['files']);baseline_rows={};baseline_states={};reports=[]
    bytes_read=0
    for ordinal,sample in enumerate(result['samples']):
        require(sample['requestSHA256']==hashes[ordinal],'Width actual request fingerprint')
        binding(sample['binding'],result['sourceLoad'])
        equal(sample['binding'],result['samples'][0]['binding'],'Width exact actual full-state geometry/model binding')
        rows=[]
        for row in sample['rows']:
            record=parse_json(files.read(row['file']))
            raw=logical_bytes(record,262144,record['dtype']);bytes_read+=len(raw)
            require(record['values'].index(max(record['values']))==row['argmax'],'Width full-row argmax evidence')
            output=row['outputOrdinal']
            if ordinal==0:baseline_rows[output]=(record['dtype'],raw)
            reference_dtype,reference=baseline_rows[output]
            require(reference_dtype==record['dtype'],'Width same native row dtype')
            rows.append(dict(outputOrdinal=output,logicalInputFrontier=row['logicalInputFrontier'],
                dtype=record['dtype'],nativeBytes=len(raw),referenceSHA256=digest(reference),candidateSHA256=digest(raw),
                **mismatch(reference,raw,record['dtype'])))
        states=[]
        for key,entry in native_state(sample,files):
            dtype,shape,logical,raw=entry;bytes_read+=len(raw)
            if ordinal==0:baseline_states[key]=entry
            expected=baseline_states[key];equal(entry[:3],expected[:3],'Width state dtype/shape/range differs')
            states.append(dict(globalLayer=key[0],component=key[1],dtype=dtype,shape=shape,logicalRange=logical,
                nativeBytes=len(raw),referenceSHA256=digest(expected[3]),candidateSHA256=digest(raw),
                **mismatch(expected[3],raw,dtype)))
        reports.append(dict(ordinal=ordinal,mode=sample['mode'],projectionPolicy=sample['projectionPolicy'],rows=rows,state=states,
            exactRows=sum(x['exact'] for x in rows),exactStateComponents=sum(x['exact'] for x in states),
            allActualArgmaxMatchReference=sample['allArgmaxMatchReference']))
    files.finish()
    # Baseline is the reference itself; actual comparisons are18 rows/270 state
    # components. All24 rows/360 components were still read and validated.
    exact=all(s['exactRows']==6 and s['exactStateComponents']==90 and s['allActualArgmaxMatchReference'] for s in reports)
    return dict(schema='gemma4_target_width_exact_numerical_comparison_v1',exactNumericsPassed=exact,
        projectionPolicy=POLICY,gatheredOverrideEnabled=False,ordinaryAndWidthOneUnhooked=True,
        requests=4,fullRowsRead=24,fullRowsComparedToReference=18,vocabularyValuesPerRow=262144,
        nativeStateComponentsRead=360,nativeStateComponentsComparedToReference=270,
        nativeBytesRead=bytes_read,checkpointFrontier=132,finalStateCompared=False,
        sampledOutputOrdinals=list(ROW_ORDINALS),allIntermediateRowsCompared=False,
        teacherForcedVariants=True,assistantUsed=False,toleranceApplied=False,
        samples=reports,retainedSidecarPins=files.pins,
        interpretation='Exact first-window target/verification/rollback isolation; no performance, long-context or remote qualification.')
