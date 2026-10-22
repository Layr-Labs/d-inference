#!/usr/bin/env python3
"""Prospective serial identity derived without reading a generation candidate sidecar."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path('/Users/developer/DarkbloomDev/cluster-research')
ORACLE = ROOT / 'generation128-numerical-audit-draft-20260915'
ORACLE_MANIFEST = '98c5e7fb6dbc9bc8b249391900ce5d9f097e503b8d82eab40983cc4a656e3d9c'
assert hashlib.sha256((ORACLE/'manifest.json').read_bytes()).hexdigest() == ORACLE_MANIFEST
for name, row in json.loads((ORACLE/'manifest.json').read_bytes())['members'].items():
    assert hashlib.sha256((ORACLE/name).read_bytes()).hexdigest() == row['sha256']
sys.path.insert(0, str(ORACLE))
from audit_common import (ARTIFACT, CONFIG, PLAN, STAGES, CONSTRUCTIONS, ARITHMETIC,
    PROMPT_SHA, REQUEST_ID, profile, exact, request_context, agreement, parse)
from recorded_math import canonical, digest
from snapshot import snapshot


def derive():
    observed = []
    def read(path, limit=1024*1024):
        item = snapshot(path, limit)
        observed.append((path, limit, item))
        return item['raw']
    config = ROOT/'owner-native-generation128-20260915/configuration'
    controller = parse(read(config/'controller.json'))
    scope = parse(read(config/'scope.json'))
    prompt = read(ROOT/'full-generation-reference-physical-20260915/returned/prompt.json')
    exact(digest(prompt), PROMPT_SHA, 'matched raw prompt')
    exact(controller['promptTokenIDs'], parse(prompt), 'declared prompt IDs')
    exact(controller['cpuQualification'], False, 'native mode')
    exact(controller['expectedTokenIDs'], None, 'no invented expected native output')
    for key, expected in dict(requestID=REQUEST_ID, outputCount=128, chunkSize=512, stopTokenIDs=[]).items():
        exact(controller[key], expected, 'declared request.' + key)
    for key, expected in dict(requestID=REQUEST_ID, cut=4, outputCount=128, mtpEnabled=False,
                              promptSHA256=PROMPT_SHA, membershipEpoch=controller['membershipEpoch']).items():
        exact(scope[key], expected, 'scope.' + key)
    context = request_context(prompt, REQUEST_ID)
    arithmetic = dict(contract='qwen_cbv2_query128_bf16_tf32_default_v1',
        requiredValues={'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK':'128','DARKBLOOM_BF16_WEIGHTS':'1','MLX_ENABLE_TF32':'1'},
        requiredAbsentNames=['MLX_METAL_GPU_ARCH','MLX_SDPA_BLOCKS'], full512TokenChunkQueryBlocks=4,
        defaultBindings={
            'MLX_METAL_GPU_ARCH':'detect actual Metal device architecture; no override',
            'MLX_SDPA_BLOCKS':'source default 0; native adaptive block selection',
            'MLX_ENABLE_TF32':'explicit 1 matches pinned source default; permits eligible NAX paths',
            'DARKBLOOM_BF16_WEIGHTS':'explicit 1 converts stored Float16 tensors to BFloat16 before subsequent arithmetic',
            'DARKBLOOM_CBV2_ATTN_QUERY_BLOCK':'explicit 128 matches pinned source default; chunk512 uses four query blocks'},
        actualProcessEnvironmentMustBePassedBeforeMLXInitialization=True,
        sourceBinaryMetalLibraryAndHardwareIdentityStillRequired=True,
        sameChunkFullModelReferenceStillRequired=True, doesNotValidateOtherTimingOrResourceEnvironment=True,
        numericalOrPerformanceQualificationEstablished=False)
    native = Path('/Users/developer/DarkbloomDev/d-inference/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')
    arithmetic_source = read(native/'QwenLongPrefillArithmeticEnvironment.swift').decode()
    for name, value in arithmetic['defaultBindings'].items():
        assert '"' + name + '": "' + value + '"' in arithmetic_source
    exact(digest(canonical(arithmetic)), ARITHMETIC, 'source-derived arithmetic receipt hash')
    for name in ('QwenResidentRuntime.swift','QwenResidentAdmission.swift','QwenLayerStageGenerationAgreement.swift'):
        read(native/name)
    builds, loads = [], []
    for rank in (0, 1):
        owner = parse(read(config/('owner-rank' + str(rank) + '.json')))
        exact(owner['stageCut'], 4, 'owner cut')
        for name, value in arithmetic['requiredValues'].items():
            exact(owner['workerEnvironment'][name], value, 'declared worker arithmetic')
        assert all(name not in owner['workerEnvironment'] for name in arithmetic['requiredAbsentNames'])
        ready = parse(base64.b64decode(owner['readyTemplateBase64'], validate=True))['ready']
        exact(ready['rank'], rank, 'template rank')
        exact(ready['executionPlanSHA256'], PLAN, 'template plan')
        identity = ready['identity']
        exact(identity['artifactSHA256'], ARTIFACT, 'template artifact')
        exact(identity['configurationSHA256'], CONFIG, 'template configuration')
        exact(identity['modelID'], 'registered_qwen35_9b', 'template model')
        rank_builds = [peer['buildSHA256'] for peer in identity['peers']]
        exact(rank_builds, [scope['nativeSHA256']]*2, 'declared rank builds')
        builds.append(rank_builds)
        event = parse(read(ROOT/('resident-physical-attempt9-cut4-20260915/events/rank-' + str(rank) + '-00-ready.jsonl')))
        exact(event['rank'], rank, 'old source receipt rank')
        execution = event['record']['execution']
        exact(execution['arithmeticEnvironment'], arithmetic, 'old source arithmetic receipt')
        exact(execution['arithmeticEnvironmentSHA256'], ARITHMETIC, 'old source arithmetic hash')
        load = execution['sourceLoad']
        for key, expected in dict(stageIndex=rank, planSHA256=PLAN, stagePlanSHA256=STAGES[rank],
            sourceConfigurationSHA256=CONFIG, constructionConfigurationSHA256=CONSTRUCTIONS[rank],
            verifiedAggregateSHA256=ARTIFACT).items():
            exact(load[key], expected, 'old source receipt.' + key)
        loads.append(load)
    exact(builds[0], builds[1], 'both owner build declarations')
    exact(loads[0]['storageCommitmentSHA256'], loads[1]['storageCommitmentSHA256'], 'old common storage commitment')
    expected = dict(schema='qwen_stage_generation_agreement_v1', rankCount=2,
        membershipEpoch=controller['membershipEpoch'], requestID=REQUEST_ID,
        requestFingerprint=context['fingerprint'], profileFingerprint=profile()['fingerprint'],
        sourceConfigurationSHA256=CONFIG, artifactAggregateSHA256=ARTIFACT,
        storageCommitmentSHA256=loads[0]['storageCommitmentSHA256'], planFingerprint=PLAN,
        stageFingerprints=list(STAGES), rankBuildSHA256=builds[0], numericalPolicySHA256=ARITHMETIC, mtpEnabled=False)
    fingerprint = agreement(expected, context)
    for path, limit, old in observed:
        assert snapshot(path, limit) == old, 'Derivation input changed'
    provenance = dict(schema='private_generation128_expected_agreement_derivation_v1', status='passed',
        oracleManifestSHA256=ORACLE_MANIFEST, expectedAgreementSHA256=digest(canonical(expected)),
        nativeAgreementFingerprint=fingerprint, numericalPolicySHA256=ARITHMETIC,
        candidateSidecarsRead=False, storageCommitmentFromPriorCut4LoadReceipts=True,
        storageCommitmentIndependentlyRecomputed=False, nativeBuildOrExecutionAttested=False,
        inputs=[dict(path=str(path),sha256=item['sha256'],bytes=item['size_bytes']) for path,_,item in observed])
    return expected, provenance


if __name__ == '__main__':
    p=argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('--output-directory', required=True)
    args=p.parse_args()
    output=Path(args.output_directory)
    output.mkdir()
    expected, provenance=derive()
    (output/'expected-agreement.json').write_bytes(canonical(expected)+b'\n')
    (output/'derivation.json').write_bytes(canonical(provenance)+b'\n')
    print(json.dumps({k:provenance[k] for k in ('status','nativeAgreementFingerprint','candidateSidecarsRead')},sort_keys=True))
