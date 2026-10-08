#!/usr/bin/env python3
"""Construct the expected agreement before candidate access; opaque identity pins are caller supplied."""
import argparse
import json
from pathlib import Path
from audit_common import agreement, canonical_uuid, parse, profile, request_context, sha, exact
from audit_generation import write_result
from audit_scope import pinned_scope
from snapshot import snapshot


def expected(request_raw, plan_raw, prompt_raw, epoch, storage, numerical_policy):
    request, plan = parse(request_raw), parse(plan_raw)
    scope = pinned_scope(request, plan)
    context = request_context(prompt_raw, request['requestID'], scope)
    exact(context['prompt_sha'], sha(request['promptFileSHA256']), 'expected prompt raw pin')
    exact(context['prompt_tokens_sha'], sha(request['promptTokenIDsSHA256']), 'expected prompt ID pin')
    result = dict(schema='qwen_stage_generation_agreement_v1', rankCount=2,
        membershipEpoch=canonical_uuid(epoch), requestID=context['request_id'],
        requestFingerprint=context['fingerprint'], profileFingerprint=profile(scope)['fingerprint'],
        sourceConfigurationSHA256=scope.model['configuration'], artifactAggregateSHA256=scope.model['artifact'],
        storageCommitmentSHA256=sha(storage), planFingerprint=scope.plan['fingerprint'],
        stageFingerprints=scope.plan['stages'], rankBuildSHA256=[sha(plan['nativeBinarySHA256'])] * 2,
        numericalPolicySHA256=sha(numerical_policy), mtpEnabled=False,
        prefillSchedulingPolicy='oneChunkLookahead')
    agreement(result, context)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    for name in ('request', 'plan', 'prompt'):
        parser.add_argument('--' + name, required=True)
        parser.add_argument('--' + name + '-sha256', required=True)
    parser.add_argument('--epoch', required=True)
    parser.add_argument('--storage-commitment-sha256', required=True)
    parser.add_argument('--numerical-policy-sha256', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    saved = []
    for name, limit in [('request', 64*1024), ('plan', 64*1024), ('prompt', 256*1024)]:
        path = Path(getattr(args, name)).absolute()
        item = snapshot(path, limit)
        exact(item['sha256'], sha(getattr(args, name + '_sha256')), name + ' raw pin')
        saved.append((path, limit, item))
    result = expected(*(item['raw'] for _, _, item in saved), args.epoch,
                      args.storage_commitment_sha256, args.numerical_policy_sha256)
    for path, limit, item in saved:
        exact(snapshot(path, limit, keep=False), dict(item, raw=None), 'input recheck')
    write_result(args.output, result)
    print(json.dumps(dict(status='prepared', candidateInputsRead=False, nativeExecutionBindingVerified=False)))


if __name__ == '__main__':
    main()
