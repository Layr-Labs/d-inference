"""Registered selected-embedding receipt, separate from physical admission."""
from binding_common import require
from dense_contract import EMBEDDING_SHA256

NAMES=['language_model.model.embed_tokens.'+suffix for suffix in ('biases','scales','weight')]
ARTIFACT='2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785'
CONFIGURATION='29910322dd085f45c8f95c6c0f1611b20f722d6f6c8394321b34817e98a972fa'

def embedding_load(value):
    require(type(value) is dict and set(value)=={'artifactSHA256','configurationSHA256','embeddingIdentitySHA256',
        'selectedNames','selectedTensorCount','loadedTensorBytes','largestHostTensorBytes','readAccounting',
        'resourceAdmissionEstablished'},'Selected embedding receipt fields')
    require(value['artifactSHA256']==ARTIFACT and value['configurationSHA256']==CONFIGURATION
        and value['embeddingIdentitySHA256']==EMBEDDING_SHA256 and value['selectedNames']==NAMES,
        'Registered selected embedding identity and ordered tensor names')
    for key,expected in [('selectedTensorCount',3),('loadedTensorBytes',415236096),('largestHostTensorBytes',369098752)]:
        require(type(value[key]) is int and value[key]==expected,'Selected embedding '+key)
    require(value['resourceAdmissionEstablished'] is False,'Embedding receipt must not grant admission')
    accounting=value['readAccounting']
    counters=['selectedBytes','requestedReadBytes','returnedReadBytes','paddingReadBytes','preadCalls',
        'interruptedCalls','shortEOFReads','largestScratchRequestBytes','largestScratchAllocationBytes']
    require(type(accounting) is dict and set(accounting)==set(counters)|{'schema','alignmentBytes',
        'maximumScratchAllocationBytes','cacheBypassRequested','readAheadDisabledRequested','fileCacheAbsenceEstablished'},
        'Selected embedding read-accounting fields')
    require(accounting['schema']=='checkpoint_aligned_selected_read_v1'
        and type(accounting['alignmentBytes']) is int and accounting['alignmentBytes']==16384
        and type(accounting['maximumScratchAllocationBytes']) is int and accounting['maximumScratchAllocationBytes']==8404992
        and accounting['cacheBypassRequested'] is True and accounting['readAheadDisabledRequested'] is True
        and accounting['fileCacheAbsenceEstablished'] is False,'Selected embedding read policy')
    require(all(type(accounting[k]) is int and accounting[k]>=0 for k in counters),'Selected embedding read counter type')
    require(accounting['selectedBytes']==415236096
        and accounting['requestedReadBytes']>=accounting['returnedReadBytes']>=accounting['selectedBytes']
        and accounting['paddingReadBytes']==accounting['returnedReadBytes']-accounting['selectedBytes']
        and accounting['preadCalls']>=3
        and accounting['interruptedCalls']<=accounting['preadCalls']
        and accounting['shortEOFReads']<=accounting['preadCalls']
        and 0<accounting['largestScratchRequestBytes']<=8388608
        and accounting['largestScratchRequestBytes']<=accounting['largestScratchAllocationBytes']<=8404992,
        'Selected embedding read accounting')

def assistant_load_completion(value):
    """The same original owner completes 94 assistant + three embedding reads."""
    require(type(value['resources']['completedItems']) is int and value['resources']['completedItems']==97,
        'Assistant owner must complete all 97 selected tensors')
    embedding_load(value.get('embeddingLoad'))
