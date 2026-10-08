"""Bounded retained-evidence diagnostic. No tolerance gate and no model execution."""
import array
from collections import Counter
import gc
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import struct
import sys

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
FROZEN = BASE / 'local-mtp-p128-comparison'
PINS = {'compare.py':'f2dcc1caa9cc6fca58808b54eb58f45e39c305562c6ad1cfec99d75fe91dbfcc',
        'recorded_math.py':'f166a6a27c20021c30c62e6966e63583b9ecab955a3b23af64869cd821f25914',
        'snapshot.py':'46dfa5689fba4358412c6c4ce03a759ca71d5c30bcde9df995a46c4aad97873b'}
for name, wanted in PINS.items():
    assert hashlib.sha256((FROZEN/name).read_bytes()).hexdigest() == wanted
sys.path.insert(0, str(FROZEN))
import compare as strict

assert sys.byteorder == 'little'
BF16 = tuple(struct.unpack('<f',struct.pack('<I',i << 16))[0] for i in range(65536))


def values(raw, dtype):
    if dtype == 'bfloat16': return (BF16[x] for x in memoryview(raw).cast('H'))
    return (x[0] for x in struct.iter_unpack({'float16':'<e','float32':'<f','int32':'<i'}[dtype],raw))


def coordinate(index, shape):
    out=[]
    for width in reversed(shape):
        out.append(index % width); index //= width
    return list(reversed(out))


def metrics(a,b,dtype,shape):
    assert len(a)==len(b)==math.prod(shape)*strict.WIDTH[dtype]
    width=strict.WIDTH[dtype]; count=math.prod(shape)
    words='H' if width==2 else 'I'
    word_a=memoryview(a).cast(words); word_b=memoryview(b).cast(words)
    different=0; numerical=0; signed_zero=0; first=None; maximum=0.0; max_index=0
    max_values=None; nonfinite_a=0; nonfinite_b=0
    sums=[[],[],[]]; blocks=[[],[],[]]
    per_position=[0]*shape[2] if len(shape)==4 else None
    for i,(x,y) in enumerate(zip(values(a,dtype),values(b,dtype))):
        if not math.isfinite(x): nonfinite_a+=1
        if not math.isfinite(y): nonfinite_b+=1
        assert math.isfinite(x) and math.isfinite(y), 'Frozen parser should reject nonfinite values first'
        if word_a[i] != word_b[i]:
            different+=1
            if first is None: first=i
            if x==y==0: signed_zero+=1
            if per_position is not None: per_position[(i//shape[3])%shape[2]]+=1
        if x!=y: numerical+=1
        d=x-y; absolute=abs(d)
        if absolute>maximum: maximum=absolute;max_index=i;max_values=[x,y]
        blocks[0].append(d*d);blocks[1].append(x*x);blocks[2].append(y*y)
        if len(blocks[0])==4096:
            for target,block in zip(sums,blocks): target.append(math.fsum(block));block.clear()
    for target,block in zip(sums,blocks): target.append(math.fsum(block))
    squared=[math.fsum(x) for x in sums]
    rms=[math.sqrt(x/count) for x in squared]
    out=dict(dtype=dtype,shape=shape,byteCountPerArm=len(a),elementCount=count,
             nativeBytesExactlyEqual=a==b,differingNativeElements=different,
             numericallyDifferentElements=numerical,signedZeroOnlyElements=signed_zero,
             maximumAbsoluteError=maximum,rmsError=rms[0],referenceRMS=rms[1],candidateRMS=rms[2],
             relativeRMSError=rms[0]/rms[1] if rms[1] else (0.0 if not rms[0] else None),
             relativeRMSDenominator='reference RMS; null only for nonzero error with zero reference RMS',
             referenceNonfiniteCount=nonfinite_a,candidateNonfiniteCount=nonfinite_b,
             firstDifferentCoordinate=coordinate(first,shape) if first is not None else None,
             maximumErrorCoordinate=coordinate(max_index,shape) if maximum else None,
             maximumErrorValuesReferenceCandidate=max_values,
             errorSquaredSum=squared[0],referenceSquaredSum=squared[1],candidateSquaredSum=squared[2])
    if per_position is not None:
        out.update(differingElementsByLogicalPosition=per_position,
                   differingPromptElements=sum(per_position[:128]),
                   differingGeneratedStateElements=sum(per_position[128:]),
                   firstDifferentLogicalPosition=next((i for i,n in enumerate(per_position) if n),None))
    return out


def main():
    inputs=strict.Inputs()
    for name,pin in PINS.items(): assert strict.digest(inputs.read(FROZEN/name))==pin
    failed=inputs.json(BASE/'p128-numerical-actual-1/receipt.json')
    failure=inputs.read(BASE/'p128-numerical-actual-1/stderr',16384)
    assert failed['exitCode']==1 and failed['reaped'] and failed['groupAbsent']
    assert b'Exact complete final native row differs' in failure
    build=inputs.json(BASE/'build/local-mtp-build-1.json')
    source=inputs.read(BASE/'build/applied-local-mtp.json')
    package_raw=inputs.read(BASE/'harness-local-mtp-v2/deployment/package.json')
    package=strict.parse_json(package_raw)
    native_sha=build['nativeSHA256']; native_bytes=build['nativeBytes']
    assert build['exitCode']==0 and build['compilerReaped'] and build['groupAbsent']
    assert build['sourcesSHA256']==strict.digest(source)
    native_record=[x for x in package['files'] if x['path']=='bundle/GemmaResidentBenchmark']
    assert len(native_record)==1 and native_record[0]['sha256']==native_sha and native_record[0]['bytes']==native_bytes
    cases=[BASE/'harness-local-mtp-v2/cases'/x for x in ('p128-solo-capture-1','p128-mtp2-qualification-1')]
    actual=[strict.physical(inputs,c,native_sha,native_bytes,strict.digest(package_raw),op)
            for c,op in zip(cases,('execute-solo','qualify-mtp-conditioning'))]
    jobs=[x[0] for x in actual]; reports=[x[1] for x in actual]
    strict.equal(strict.workload(jobs[0]),strict.workload(jobs[1]),'Semantic workload differs')
    assert set(jobs[0]['requestIDs']).isdisjoint(jobs[1]['requestIDs'])
    sidecars=[strict.Sidecars(inputs,x[4],x[1]['files']) for x in actual]
    unique={}; samples=[]; row_pairs=set(); state_pairs=set()
    for ordinal,(sa,sb) in enumerate(zip(reports[0]['samples'],reports[1]['samples'])):
        ga=sa;gb=sb['generation'];ea=sa;eb=sb['evidence']
        assert ga['ordinal']==gb['ordinal']==ordinal and ga['warmup']==gb['warmup']==(ordinal==0)
        assert ga['selectedTokenIDs']==gb['selectedTokenIDs'] and len(ga['selectedTokenIDs'])==16
        for s,r in zip((sa,sb),reports): strict.binding(s['binding'],r['sourceLoad'])
        strict.equal(sa['binding']['layers'],sb['binding']['layers'],'Native state shapes differ')
        rows=[]; records=[]
        for evidence,sc in zip((ea,eb),sidecars):
            record=strict.parse_json(sc.read(evidence['finalRow']))
            assert evidence['finalRow']['name']==f'request-{ordinal}-final-row.json'
            rows.append(strict.logical_bytes(record,262144,record['dtype']));records.append(record)
        assert records[0]['dtype']==records[1]['dtype']
        row_key=tuple(strict.digest(x) for x in rows);row_pairs.add(row_key)
        if row_key not in unique: unique[row_key]=metrics(*rows,records[0]['dtype'],[1,262144])
        row_metric=dict(unique[row_key],referenceSHA256=row_key[0],candidateSHA256=row_key[1],
                        referenceArgmax=records[0]['values'].index(max(records[0]['values'])),
                        candidateArgmax=records[1]['values'].index(max(records[1]['values'])))
        assert row_metric['referenceArgmax']==row_metric['candidateArgmax']==ga['selectedTokenIDs'][-1]
        del rows,records
        states=[strict.state(e['finalState'],s['binding'],sc,ordinal)
                for e,s,sc in zip((ea,eb),(sa,sb),sidecars)]
        components=[]
        for layer,component in states[0]:
            a=states[0][(layer,component)];b=states[1][(layer,component)]
            assert a[:3]==b[:3]
            key=tuple(strict.digest(x[3]) for x in (a,b));state_pairs.add(key)
            if key not in unique: unique[key]=metrics(a[3],b[3],a[0],a[1])
            components.append(dict(unique[key],globalLayer=layer,component=component,
                                   logicalRange=a[2],referenceSHA256=key[0],candidateSHA256=key[1]))
        changed=[x for x in components if not x['nativeBytesExactlyEqual']]
        sample=dict(ordinal=ordinal,warmup=ordinal==0,tokens=ga['selectedTokenIDs'],allTokensExactlyEqual=True,
                    row=row_metric,components=components,stateComponents=len(components),
                    exactStateComponents=len(components)-len(changed),differentStateComponents=len(changed),
                    stateBytesPerArm=sum(x['byteCountPerArm'] for x in components),
                    referenceStateFingerprint=ea['finalState']['fingerprint'],candidateStateFingerprint=eb['finalState']['fingerprint'],
                    earliestDifferentState={k:changed[0][k] for k in ('globalLayer','component','firstDifferentCoordinate','firstDifferentLogicalPosition')} if changed else None,
                    verificationWidths=gb['verificationWidths'],acceptedPrefixes=gb['acceptedPrefixes'],
                    proposalTokens=gb['proposalTokens'],acceptedProposalTokens=gb['acceptedProposalTokens'])
        samples.append(sample)
        print(json.dumps(dict(ordinal=ordinal,rowMaxAbs=row_metric['maximumAbsoluteError'],rowRelativeRMS=row_metric['relativeRMSError'],
                              differentStateComponents=len(changed),earliest=sample['earliestDifferentState'])),flush=True)
        del states;gc.collect()
    for sc in sidecars: assert sc.used==set(sc.files)
    inputs.recheck()
    out=dict(schema='gemma4_p128_mtp_numerical_diagnostic_v1',status='completed',
        qualificationPassed=False,exactNumericalGatePreserved=True,nativeSHA256=native_sha,
        sourceSHA256=strict.digest(source),requests=4,measuredRequests=3,warmupRequests=1,
        finalRows=4,valuesPerRow=262144,stateComponents=360,
        stateBytesComparedPerArm=sum(s['stateBytesPerArm'] for s in samples),
        allTokensExactlyEqual=True,allFinalRowsExactlyEqual=all(s['row']['nativeBytesExactlyEqual'] for s in samples),
        exactStateComponents=sum(s['exactStateComponents'] for s in samples),differentStateComponents=sum(s['differentStateComponents'] for s in samples),
        uniqueRowHashPairs=len(row_pairs),uniqueStateHashPairs=len(state_pairs),
        uniqueNumericalCalculations=len(unique),allSidecarsValidated=True,
        arithmetic='Native F16/BF16/F32 values decoded exactly; error squares accumulated in Float64 with math.fsum; no tolerances applied.',
        causalLimit='Final snapshots alone cannot distinguish width-dependent model arithmetic from verification/reconciliation implementation. No intermediate hidden/logit witness is available here.',
        executableFileRehashed=False,executableAuthority='Root qualified same-build receipt and installed package record; diagnostic replays retained evidence only.',
        physical=[x[5] for x in actual],samples=samples,retainedInputPins=list(inputs.pins.values()))
    with (HERE/'findings.json').open('x') as f: json.dump(out,f,indent=2,allow_nan=False);f.write('\n')


if __name__=='__main__': main()
