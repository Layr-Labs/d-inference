#!/usr/bin/env python3
"""Independent integer vectors from retained JSON metadata; no Swift/model IO."""
import base64
import json
import sys
from pathlib import Path


def derive(entry):
    t = json.loads(base64.b64decode(entry['configuration']))['text_config']
    n = t['num_hidden_layers']; a = n // t['full_attention_interval']; r = n-a
    h = t['hidden_size']; q = t['num_attention_heads']; k = t['num_key_value_heads']; d = t['head_dim']
    kh = t['linear_num_key_heads']; vh = t['linear_num_value_heads']
    kd = t['linear_key_head_dim']; vd = t['linear_value_head_dim']; kernel=t['linear_conv_kernel_dim']
    channels=2*kh*kd+vh*vd; conv=2*(kernel-1)*channels; ssm=4*vh*vd*kd
    states=[r*(conv+ssm)+a*(2*2*k*p*d+4) for p in [2,3,4,5]]
    named=3*r*(2*conv+ssm)+a*(2*4*5*k*d+4)+max(2*conv,ssm,4*5*k*d)+2*2*h*4
    by_name={x['name']:x for x in entry['canonicalTensors']}
    fused=[]
    for layer in range(n):
        if (layer+1)%t['full_attention_interval']==0: continue
        for suffix in ['weight','scales','biases']:
            records=[by_name[f'language_model.model.layers.{layer}.linear_attn.{part}.{suffix}']
                     for part in ['in_proj_qkv','in_proj_z','in_proj_b','in_proj_a']]
            assert len({(x['sourceDType'],tuple(x['shape'][1:])) for x in records})==1
            shape=[sum(x['shape'][0] for x in records), records[0]['shape'][1]]
            size=shape[0]*shape[1]*(4 if suffix=='weight' else 2)
            assert size==sum(x['byteCount'] for x in records)
            fused.append(size)
    state_allowance=3*r*(2*conv+ssm)+a*(2*4*5*k*d+4)
    workspace=(6*n*2*h*4 + 4*n*2*t['intermediate_size']*4
               +a*2*q*2*d*4 +2*a*2*k*d*4 +2*a*q*2*5*4
               +r*2*(channels+vh*vd+2*vh)*4 +r*(kernel-1+2)*channels*4)
    output=t['vocab_size']*6+8
    base_native=state_allowance+sum(fused)+workspace+output
    base_cpu=2*t['vocab_size']*6+max(2*conv,ssm,4*5*k*d)
    boundary=2*2*h*4
    pair_cpu=base_cpu+2*t['vocab_size']*4+t['vocab_size']*2+boundary
    return dict(layers=n, attention_layers=a, recurrent_layers=r, component_count=3*a+2*r,
                frontier_logical_bytes=states[:3], native_capacity5_state_bytes=states[3],
                convolution_shape=[1,kernel-1,channels], ssm_shape=[1,vh,vd,kd],
                kv_frontier4_shape=[1,k,4,d], fusion_logical_bytes=sum(fused),
                fusion_array_count=len(fused), largest_fused_array_bytes=max(fused),
                named_state_budget_bytes=named, identity_allocator_full_native_bytes=base_native,
                identity_allocator_pair_native_bytes=base_native+boundary,
                full_cpu_evidence_bytes=base_cpu, pair_cpu_evidence_bytes=pair_cpu,
                identity_allocator_full_reserve_bytes=base_native+base_cpu,
                identity_allocator_pair_reserve_bytes=base_native+boundary+pair_cpu,
                pair_minus_full_reserve_bytes=2*boundary+2*t['vocab_size']*4+t['vocab_size']*2)


def main():
    source=Path(sys.argv[1]); data=source.read_bytes()
    assert len(data)<=1_048_576
    entries=json.loads(data)
    result={'kind':'independent_short_ledger_integer_vectors','schemaVersion':1,
            'nativeOrSwiftExecuted':False,'allocator':'invented_identity_not_device_bound',
            'isWholeProcessMemoryBound':False,
            'vectors':{key:derive(entries[key]) for key in ['nine','twentySeven']}}
    print(json.dumps(result,sort_keys=True,indent=2,allow_nan=False))

if __name__=='__main__':main()
