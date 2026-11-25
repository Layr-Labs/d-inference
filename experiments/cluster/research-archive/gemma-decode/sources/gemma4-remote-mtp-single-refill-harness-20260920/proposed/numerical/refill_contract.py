"""Explicit refill policy only; paired/default grammar and budget remain exact."""
from binding_common import require
SINGLE='single_for_depth_one_v1'
FIELDS={'schema','role','localMTPJob','localMTPJobSHA256','targetNativeSHA256','assistantNativeSHA256','embeddingIdentitySHA256'}
META={'producerRefillPolicy','maximumProducerRefillGrant','maximumProducerLookaheadGrant'}

def refill_policy(wrapper,local):
    if 'refillPolicy' not in wrapper:return 'paired_v1'
    require(type(wrapper['refillPolicy']) is str and wrapper['refillPolicy']==SINGLE,'Unknown explicit refill policy')
    require(type(local['maximumDraftTokens']) is int and local['maximumDraftTokens']==1,'Single refill requires chosen D1')
    return SINGLE

def validate_wrapper(wrapper,local):
    require(type(wrapper) is dict and set(wrapper) in (FIELDS,FIELDS|{'refillPolicy'}),'Exact optional refill wrapper fields')
    return refill_policy(wrapper,local)

def scope_components(wrapper,local):
    return [] if validate_wrapper(wrapper,local)=='paired_v1' else ['producerRefillPolicy='+SINGLE,'producerLookaheadGrant=2']

def validate_refill_metadata(value,wrapper,local):
    if validate_wrapper(wrapper,local)=='paired_v1':
        require(not META.intersection(value),'Default path reported an enabled refill override')
    else:
        require(value.get('producerRefillPolicy')==SINGLE
            and type(value.get('maximumProducerRefillGrant')) is int and value['maximumProducerRefillGrant']==1
            and type(value.get('maximumProducerLookaheadGrant')) is int and value['maximumProducerLookaheadGrant']==2,
            'Actual refill metadata differs from explicit policy')
