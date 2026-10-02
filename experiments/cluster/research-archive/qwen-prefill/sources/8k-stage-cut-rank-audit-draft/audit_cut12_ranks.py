#!/usr/bin/env python3
"""Two fixed-cut12 ranks against a separately qualified cut12 pair checkpoint."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
MAX_STDOUT = 16*1024**2
MAX_RECEIPT = 256*1024


def require(ok, message):
    if not ok: raise ValueError(message)


def bounded(path, limit):
    p=Path(path)
    require(p.is_file() and not p.is_symlink() and 0<p.stat().st_size<=limit,'Expected a bounded regular input file')
    with p.open('rb') as f: data=f.read(limit+1)
    require(0<len(data)<=limit,'Input exceeds its byte limit')
    return data


def verify_helpers():
    raw=bounded(HERE/'core-helper-pins.json',65536);pins=json.loads(raw)
    names={'cut12_rank_dependencies.py','cut12_rank_trace.py','cut12_rank_wire.py','qwen_long_prefill_rank_cut12_audit.py'}
    require(type(pins) is dict and set(pins)==names,'Closed rank-helper inventory differs')
    for name,pin in pins.items():
        require(hashlib.sha256(bounded(HERE/name,2*1024**2)).hexdigest()==pin,'Frozen rank helper differs: '+name)
    return raw


def check_pair_receipt(a, receipt, summary, pair_raw, prompt_raw):
    """Validate the saved result of the frozen pair adapter, without using its paths for IO."""
    import cut12_rank_dependencies as dep
    a.require(type(receipt) is dict and type(receipt.get('inputs')) is list and len(receipt['inputs'])==2,
        'Expected the complete qualified pair CPU result')
    inputs=[]
    for actual,raw in zip(receipt['inputs'],[pair_raw,prompt_raw]):
        a.require(type(actual) is dict and set(actual)=={'path','sizeBytes','sha256'}
            and type(actual['path']) is str and 0<len(actual['path'].encode())<=4096,
            'Qualified pair input provenance schema differs')
        inputs.append(dict(path=actual['path'],sizeBytes=len(raw),sha256=a.sha(raw)))
    a.require(inputs[0]['path']!=inputs[1]['path'],'Qualified pair origin paths are not distinct')
    expected=dict(summary,kind='qwen_long_prefill_cut12_pair_cpu_audit',schemaVersion=1,explicitStageCut=12,
        sourceLayerRanges=[[0,12],[12,32]],sourcePlanSHA256=a.context()['source']['planSHA256'],
        sameRunReferenceValidatedAgainstSelectedPlan=True,oldHalfReferenceRelabeled=False,
        modelPayloadRead=False,nativeExecutionPerformed=False,sourceAndRuntimeProvenanceIndependentlyVerified=False,
        frozenInputsUnchanged=True,inputs=inputs,
        helperSHA256=a.sha((dep.PAIR/'audit_cut12_pair.py').read_bytes()),
        referenceOracleSHA256=a.sha((dep.PAIR/'qwen_long_prefill_reference_cut12_audit.py').read_bytes()),
        helperPins=json.loads((dep.PAIR/'core-helper-pins.json').read_bytes()),dependencyPins=a.verify_pins())
    a.exact(receipt,expected,'separately qualified same-cut pair CPU result')


def validate(paths, pair_path, prompt_path, expected_prompt_sha256, epoch, policy,
             expected_pair_sha256, pair_cpu_receipt_path, expected_pair_cpu_receipt_sha256):
    """Expected pair/raw-result hashes must come from independent completed qualification."""
    require(type(paths) in (list,tuple) and len(paths)==2,'Two ordered rank stdout files required')
    inputs=[Path(x) for x in [*paths,pair_path,prompt_path,pair_cpu_receipt_path]]
    require(len({p.resolve() for p in inputs})==5,'Distinct rank/pair/prompt/receipt paths required')
    helper_pins=verify_helpers();own=Path(__file__).read_bytes()
    import cut12_rank_dependencies as dep
    import qwen_long_prefill_rank_cut12_audit as audit
    a=dep.context()[0]
    before=dep.verify_pins();reference_before=a.verify_pins()
    limits=[MAX_STDOUT,MAX_STDOUT,MAX_STDOUT,a.MAX_PROMPT,MAX_RECEIPT]
    raw=[bounded(p,n) for p,n in zip(inputs,limits)]
    require(all(b.endswith(b'\n') for b in raw[:3]),'Complete rank and pair JSONL records required')
    require(a.sha(raw[2])==a.sha_string(expected_pair_sha256),'Independent qualified pair stdout pin differs')
    require(a.sha(raw[4])==a.sha_string(expected_pair_cpu_receipt_sha256),'Independent qualified pair CPU-result pin differs')
    pair_rows=dep.pair_oracle().parse_rows(a,raw[2])
    pair_summary=dep.pair_oracle().check_pair(a,pair_rows,raw[3],expected_prompt_sha256)
    a.check_depth(raw[4]);receipt=a.context()['base'].parse_json(raw[4].decode('utf8'))
    check_pair_receipt(a,receipt,pair_summary,raw[2],raw[3])
    result=audit.check_rank_pair([audit.parse_rows(x) for x in raw[:2]],pair_rows,raw[3],expected_prompt_sha256,epoch,policy)
    require([bounded(p,n) for p,n in zip(inputs,limits)]==raw,'Rank/reference audit inputs changed during replay')
    require(verify_helpers()==helper_pins and dep.verify_pins()==before and a.verify_pins()==reference_before
        and Path(__file__).read_bytes()==own,'Frozen rank/reference helper changed during replay')
    result.update(kind='qwen_long_prefill_cut12_rank_cpu_audit',schemaVersion=1,explicitStageCut=12,
        sourceLayerRanges=[[0,12],[12,32]],stageStateComponents=[27,45],stageLogicalStateBytes=[119980044,199966740],
        baselineContainer='qualified_cut12_one_process_pair_checkpoint',baselinePairStdoutSHA256=a.sha(raw[2]),
        baselinePairCPUReceiptSHA256=a.sha(raw[4]),sameCutPairContainerAndCPUReceiptValidated=True,
        oldStandaloneReferenceAccepted=False,oldHalfReferenceRelabeled=False,
        nativeExecutionPerformed=False,modelPayloadRead=False,sourceAndRuntimeProvenanceIndependentlyVerified=False,
        frozenInputsUnchanged=True,inputs=[dict(path=str(p.resolve()),sizeBytes=len(b),sha256=a.sha(b)) for p,b in zip(inputs,raw)],
        helperSHA256=a.sha(own),helperPins=json.loads(helper_pins),dependencyPins=before,referenceDependencyPins=reference_before)
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['rank0','rank1','pair','prompt','pair-cpu-receipt']:p.add_argument('--'+name,type=Path,required=True)
    for name in ['prompt-sha256','pair-sha256','pair-cpu-receipt-sha256','epoch','policy']:p.add_argument('--'+name,required=True)
    args=p.parse_args()
    print(json.dumps(validate([args.rank0,args.rank1],args.pair,args.prompt,args.prompt_sha256,args.epoch,args.policy,
        args.pair_sha256,args.pair_cpu_receipt,args.pair_cpu_receipt_sha256),indent=2,sort_keys=True,allow_nan=False))


if __name__=='__main__':main()
