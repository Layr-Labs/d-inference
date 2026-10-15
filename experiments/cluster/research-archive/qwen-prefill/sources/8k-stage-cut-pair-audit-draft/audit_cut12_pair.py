#!/usr/bin/env python3
"""Bounded completed-output adapter for exactly the registered 8K cut12 pair."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
MAX_STDOUT = 16*1024**2


def require(ok, message):
    if not ok: raise ValueError(message)


def bounded(path, limit):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= limit,
        'Input must be a bounded regular file')
    with path.open('rb') as stream: data = stream.read(limit+1)
    require(0 < len(data) <= limit, 'Input byte limit differs')
    return data


def verify_helpers():
    raw = bounded(HERE/'core-helper-pins.json', 65536)
    pins = json.loads(raw)
    expected = {'cut12_reference_context.py','qwen_long_prefill_reference_cut12_audit.py',
        'cut12_pair_storage.py','cut12_pair_final.py','cut12_pair_wire.py','qwen_long_prefill_pair_cut12_audit.py'}
    require(type(pins) is dict and set(pins) == expected, 'Closed helper inventory differs')
    for name, pin in pins.items():
        require(hashlib.sha256(bounded(HERE/name,2*1024**2)).hexdigest() == pin, 'Frozen helper changed: '+name)
    return raw


def validate(stdout_path, prompt_path, expected_prompt_sha256):
    """The caller independently pins exact natural prompt bytes before execution."""
    paths = [Path(stdout_path), Path(prompt_path)]
    require(paths[0].resolve() != paths[1].resolve(), 'Distinct stdout/prompt paths required')
    helper_pins = verify_helpers(); own = Path(__file__).read_bytes()
    import qwen_long_prefill_reference_cut12_audit as a
    import qwen_long_prefill_pair_cut12_audit as pair
    dependency_pins = a.verify_pins()
    raw, prompt = bounded(paths[0],MAX_STDOUT), bounded(paths[1],a.MAX_PROMPT)
    require(raw.endswith(b'\n'), 'Native stdout must contain complete JSONL records')
    result = pair.check_pair(a,pair.parse_rows(a,raw),prompt,expected_prompt_sha256)
    require(result['stageStateComponents'] == [27,45], 'Explicit selected-cut scope differs')
    require(bounded(paths[0],MAX_STDOUT) == raw and bounded(paths[1],a.MAX_PROMPT) == prompt,
        'CPU audit inputs changed during replay')
    require(verify_helpers() == helper_pins and a.verify_pins() == dependency_pins
        and Path(__file__).read_bytes() == own, 'CPU audit helper/dependency changed during replay')
    result.update(kind='qwen_long_prefill_cut12_pair_cpu_audit',schemaVersion=1,explicitStageCut=12,
        sourceLayerRanges=[[0,12],[12,32]],sourcePlanSHA256=a.context()['source']['planSHA256'],
        sameRunReferenceValidatedAgainstSelectedPlan=True,oldHalfReferenceRelabeled=False,
        modelPayloadRead=False,nativeExecutionPerformed=False,
        sourceAndRuntimeProvenanceIndependentlyVerified=False,frozenInputsUnchanged=True,
        inputs=[dict(path=str(p.resolve()),sizeBytes=len(b),sha256=a.sha(b)) for p,b in zip(paths,[raw,prompt])],
        helperSHA256=a.sha(own),referenceOracleSHA256=a.sha((HERE/'qwen_long_prefill_reference_cut12_audit.py').read_bytes()),
        helperPins=json.loads(helper_pins),dependencyPins=dependency_pins)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--stdout',required=True,type=Path)
    p.add_argument('--prompt',required=True,type=Path)
    p.add_argument('--prompt-sha256',required=True)
    args = p.parse_args()
    print(json.dumps(validate(args.stdout,args.prompt,args.prompt_sha256),indent=2,sort_keys=True,allow_nan=False))


if __name__ == '__main__': main()
