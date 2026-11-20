"""Closed primitive numerical evidence; explicitly no model qualification."""
import math
from pathlib import Path
import re
from binding_common import require

DENSE = [(2816,4096,4),(2816,2048,4),(2816,8192,4),(2816,1024,4),(4096,2816,4),
         (8192,2816,4),(2816,2112,8),(2112,2816,8),(2816,128,8)]
RESERVE=64*1024**2

def mode_for_run(path):
    names={'small-qmv-dense-1-full':'dense','small-qmv-gathered-1-full':'gathered'}
    require(Path(path).name in names,'Closed primitive case name required')
    return names[Path(path).name]

def expected(mode):
    rows={}
    for dtype in ('bfloat16','float32'):
        if mode=='dense':
            for k,n,bits in DENSE:
                one=32//bits;vpt=2*one if k%(one*64)==0 else one
                for width in (1,2,3):
                    for cancel in (False,True):
                        name=f'dense/w{bits}-k{k}-n{n}/{dtype}/m{width}/cancel-{str(cancel).lower()}'
                        rows[name]=dict(kind='dense',K=k,N=n,bits=bits,dtype=dtype,rows=width,
                            valuesPerLane=vpt,reference='independent-ordinary-M1-quantizedMM',cancellationInput=cancel)
        else:
            for bank,k,n in [('gate',2816,704),('up',2816,704),('down',704,2816)]:
                for layout in ('tokenRows','assignmentRows'):
                    for width in (1,2,3):
                        for pattern in ('disjoint','shared','partial','permuted'):
                            route=[]
                            for token in range(width):
                                for slot in range(8):
                                    if pattern=='disjoint':expert=token*8+slot
                                    elif pattern=='shared':expert=16+slot
                                    elif pattern=='partial':expert=slot if slot<4 else 4+token*4+slot
                                    else:expert=16+(slot+token*3)%8
                                    route.append(expert)
                            for cancel in (False,True):
                                name=f'gather/{bank}/{dtype}/{layout}/t{width}-{pattern}/cancel-{str(cancel).lower()}'
                                rows[name]=dict(kind='gather',K=k,N=n,bits=4,dtype=dtype,rows=width,topK=8,
                                    experts=24,distinctExperts=len(set(route)),inputLayout=layout,route=route,
                                    cancellationInput=cancel,reference='unchanged-unsorted-gatherQuantizedMM')
    return rows

def sha(value):
    require(isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value),'Invalid result hash')

def durations(value):
    require(isinstance(value,list) and len(value)==3 and all(type(x) is int and 0<x<300*10**9 for x in value),
            'Three actual positive primitive durations required')

def validate_result(value,mode):
    require(mode in ('dense','gathered') and isinstance(value,dict),'Unknown qualifier mode')
    names=expected(mode);count=108 if mode=='dense' else 288
    require(value['schema']=='gemma_small_qmv_result_v1' and value['mode']=='--'+mode
        and value['passed'] is True and type(value['caseCount']) is int and value['caseCount']==count,
        'Primitive terminal/count differs')
    for name,wanted in dict(warmupCount=1,measurementCount=3,gatheredDeviceRefusalControls=0 if mode=='dense' else 12,
                            nativeExtraReserveBytes=RESERVE,hostReserveBytes=RESERVE,cacheBytesAfterRelease=0).items():
        require(type(value[name]) is int and value[name]==wanted,'Primitive bound/count differs: '+name)
    for name in ('runtimeServingEnabled','modelExecuted','defaultDispatchChanged','physicalProcessOrLeaseRetirementEstablished'):
        require(value[name] is False,'Unexpected qualification claim: '+name)
    require(type(value['resourceObservations']) is int and value['resourceObservations']>0
        and type(value['minimumActualFreeBytes']) is int and value['minimumActualFreeBytes']>=10*1024**3+2*RESERVE
        and type(value['peakExtraActiveBytes']) is int and 0<=value['peakExtraActiveBytes']<=RESERVE,
        'Native resource observation differs')
    rows=value['cases'];require(isinstance(rows,list) and len(rows)==count,'Case count differs')
    observed={x['name']:x for x in rows};require(len(observed)==count and set(observed)==set(names),'Missing/duplicate/foreign case')
    for name,row in observed.items():
        for key,wanted in names[name].items():
            require(type(row[key]) is type(wanted) and row[key]==wanted,'Case source geometry/route differs: '+name+'/'+key)
        require(row['passed'] is True and row['exactOutputBytes'] is True and row['finite'] is True
            and type(row['maximumDifferentBytes']) is int and row['maximumDifferentBytes']==0,'Actual primitive bytes differ: '+name)
        sha(row['referenceSHA256']);sha(row['candidateSHA256'])
        require(row['referenceSHA256']==row['candidateSHA256'],'Exact flag/hash mismatch')
        durations(row['referenceNanoseconds']);durations(row['candidateNanoseconds'])
        if mode=='dense':
            require(type(row['currentBatchExactToM1']) is bool,'Missing actual current batch comparison')
            sha(row['currentBatchSHA256']);durations(row['currentBatchNanoseconds'])
            for key in ('currentBatchMaximumAbsoluteError','currentBatchMaximumRelativeRMSError'):
                require(type(row[key]) in (int,float) and math.isfinite(row[key]) and row[key]>=0,'Invalid current batch error')
        elif name.startswith('gather/down/'):
            require(row['weightedOriginalSlotsExact'] is True,'Weighted original-slot output differs')
            sha(row['weightedReferenceSHA256']);sha(row['weightedCandidateSHA256'])
            require(row['weightedReferenceSHA256']==row['weightedCandidateSHA256'],'Weighted output hash differs')
    return value
