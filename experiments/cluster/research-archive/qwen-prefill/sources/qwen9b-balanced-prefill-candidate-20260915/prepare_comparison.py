#!/usr/bin/env python3
"""Root-only local packet construction after bounded sidecar retrieval; no numerical policy changes."""
import argparse
import hashlib
import os
from pathlib import Path
import sys
from prepare_configuration import BASE, RESEARCH, record

REFERENCE = RESEARCH / 'full-generation-reference-physical-20260915/returned/native/worker-0.stdout'
REFERENCE_SHA = '748b2d11346b3097435f83db53296c4873c3e42a261493614cbfe896883faaa3'

def main():
    p=argparse.ArgumentParser(description=__doc__,allow_abbrev=False)
    p.add_argument('--case',required=True,choices=['cut4-correctness','cut16-correctness'])
    p.add_argument('--rank0',required=True);p.add_argument('--rank1',required=True)
    p.add_argument('--output',required=True)
    a=p.parse_args()
    audit=BASE/'cut16-audit' if a.case.startswith('cut16-') else RESEARCH/'generation128-lookahead-audit-draft-20260915'
    sys.path.insert(0,str(audit))
    from snapshot import snapshot
    from audit_common import parse,request_context,agreement,REQUEST_ID,PROMPT_SHA
    expected=parse((BASE/'cases'/a.case/'configuration/expected-agreement.json').read_bytes())
    paths={'prompt':BASE/'inputs/prompt.ids.json','reference_stdout':REFERENCE,
           'rank0_evidence':Path(a.rank0).absolute(),'rank1_evidence':Path(a.rank1).absolute()}
    caps={'prompt':256*1024,'reference_stdout':32*1024**2,'rank0_evidence':16*1024**2,'rank1_evidence':16*1024**2}
    items={name:snapshot(path,caps[name]) for name,path in paths.items()}
    if items['prompt']['sha256']!=PROMPT_SHA or items['reference_stdout']['sha256']!=REFERENCE_SHA:
        raise ValueError('Frozen matched reference/prompt changed')
    if len({x['identity'][:2] for x in items.values()})!=4:
        raise ValueError('Distinct raw inputs required')
    agreement(expected,request_context(items['prompt']['raw'],REQUEST_ID))
    packet=dict(schema='private_generation128_comparison_packet_v1',request_id=REQUEST_ID,
        expected_agreement=expected,files={k:dict(path=str(paths[k]),sha256=v['sha256']) for k,v in items.items()})
    for name,item in items.items():
        if snapshot(paths[name],caps[name],keep=False)!=dict(item,raw=None):
            raise ValueError('Comparison input changed during packet construction')
    raw=record(packet)
    fd=os.open(a.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_CLOEXEC,0o600)
    with os.fdopen(fd,'wb') as out:out.write(raw);out.flush();os.fsync(out.fileno())
    print(hashlib.sha256(raw).hexdigest())

if __name__=='__main__':main()
