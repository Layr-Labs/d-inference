"""Validate the new full reference under the frozen cut16 policy; no candidate input."""
import argparse
import json
from pathlib import Path
import sys
from assemble import BASE, pin

AUDIT = BASE.parent / 'qwen27b-cut16-numerical-audit-20260915'
sys.path.insert(0, str(AUDIT))
from audit_scope import pinned_scope
from audit_common import agreement, request_context
from audit_reference import check_reference
from audit_generation import write_result
from snapshot import snapshot


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--reference', required=True)
    parser.add_argument('--reference-sha256', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    assert pin(AUDIT / 'manifest.json')['sha256'] == 'f3757094f14cc479e761b83b2a988551250bd61a9dba1797e91c3e564f29aebe'
    for row in json.loads((AUDIT / 'manifest.json').read_bytes())['files']:
        actual = pin(AUDIT / row['path'])
        assert (actual['bytes'], actual['sha256']) == (row['bytes'], row['sha256'])
    request = json.loads((BASE / 'inputs/request.json').read_bytes())
    metadata = json.loads((BASE / 'provenance/recording-metadata.json').read_bytes())
    scope = pinned_scope(request, metadata)
    prompt = (BASE / 'inputs/prompt.ids.json').read_bytes()
    context = request_context(prompt, request['requestID'], scope)
    assert context['prompt_sha'] == request['promptFileSHA256']
    assert context['prompt_tokens_sha'] == request['promptTokenIDsSHA256']
    agreement(json.loads((BASE / 'expected-agreement.json').read_bytes()), context)
    path = Path(args.reference).absolute()
    saved = snapshot(path, 32 * 1024 * 1024)
    assert saved['sha256'] == args.reference_sha256
    result = check_reference(saved['raw'], context)
    assert snapshot(path, 32 * 1024 * 1024, keep=False) == dict(saved, raw=None)
    write_result(args.output, dict(referenceValidated=True, referenceSHA256=saved['sha256'],
        modelID=scope.model_id, stageCut=scope.cut, planSHA256=scope.plan['fingerprint'],
        selectedTokenCount=len(result['selected']), frames=scope.frames, frontier=scope.frontier,
        finalBF16RowBytes=len(result['final_bytes']), stateEntries=len(result['entries']),
        candidateRead=False, candidateNumericalComparisonPerformed=False, physicalCleanupAttested=False))
    print(json.dumps(dict(referenceValidated=True, output=args.output)))


if __name__ == '__main__':
    main()
