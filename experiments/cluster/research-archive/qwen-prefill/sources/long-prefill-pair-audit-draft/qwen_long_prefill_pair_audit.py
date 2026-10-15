"""Prospective CPU validator for two-record, one-process registered8K pair checks.

The nested full-reference oracle is supplied with an independent source pin.
No model, native library, transport, timing or candidate logit row is executed.
"""
import argparse
import importlib.util
import json
from pathlib import Path

from pair_storage import check_storage, identity
from pair_wire import agreement, check_frames, token
from pair_final import check_finals

MAX_STDOUT = 16 * 1024**2
PHASES = ['before_baseline_load', 'baseline_released_cache_cleared', 'both_stages_loaded',
          'stage_requests_retired_weights_resident', 'stage_models_released_cache_cleared']


def load_reference_oracle(path, expected_sha256):
    import hashlib
    raw = Path(path).read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected_sha256:
        raise ValueError('Independent reference-oracle source pin differs')
    spec = importlib.util.spec_from_file_location('pair_pinned_reference_oracle', path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


def parse_rows(a, data):
    a.require(type(data) is bytes and 0 < len(data) <= MAX_STDOUT, 'Pair stdout exceeds bound')
    lines = data.splitlines()
    a.require(len(lines) == 2 and all(lines), 'Exactly checkpoint and final report required')
    rows = []
    for line in lines:
        a.check_depth(line)
        rows.append(a.context()['base'].parse_json(line.decode('utf8')))
    return rows


def memory(a, checkpoint, report):
    a.require(type(report) is list and len(report) == 5, 'Five native allocator observations required')
    a.exact(checkpoint, report[:2], 'retained baseline allocator observations')
    peak = 0
    for item, phase in zip(report, PHASES):
        a.require(type(item) is dict and set(item) == {'phase','activeMLXBytes','cachedMLXBytes','peakMLXBytesSinceProcessStart'},
                  'Allocator observation fields differ')
        a.exact(item['phase'], phase, 'allocator phase')
        active = a.integer(item['activeMLXBytes']); a.integer(item['cachedMLXBytes'])
        current = a.integer(item['peakMLXBytesSinceProcessStart'])
        a.require(current >= active and current >= peak, 'Native peak arithmetic is inconsistent')
        peak = current
    a.require(report[1]['cachedMLXBytes'] == report[-1]['cachedMLXBytes'] == 0, 'Native cache-clear assertions differ')


def check_pair(a, rows, prompt_data, expected_prompt_sha256):
    a.require(type(rows) is list and len(rows) == 2 and all(type(x) is dict for x in rows), 'Two outer objects required')
    checkpoint, report = rows
    a.require(set(checkpoint) == {'kind','schemaVersion','baselineModelReleasedBeforeStageLoading','reference','memory'},
              'Checkpoint schema differs')
    for key, value in dict(kind='qwen_long_prefill_pair_reference_checkpoint',schemaVersion=1,
                           baselineModelReleasedBeforeStageLoading=True).items():
        a.exact(checkpoint[key], value, 'checkpoint.' + key)
    reference = checkpoint['reference']
    baseline = a.check_reference(reference, prompt_data, expected_prompt_sha256)
    wanted = dict(kind='qwen_long_prefill_pair_report',schemaVersion=1,correctnessOnly=True,
        throughputMeasurementValid=False,interprocessTransportUsed=False,physicalTransferQualified=False,
        baselineModelReleasedBeforeStageLoading=True,stageModelsReleased=True,allRequestStateRetired=True)
    a.require(set(report) == set(wanted) | {'stageLoads','comparison','memory'}, 'Pair report schema differs')
    for key,value in wanted.items(): a.exact(report[key], value, 'report.' + key)
    memory(a, checkpoint['memory'], report['memory'])
    loads = report['stageLoads']
    inventory, _ = check_storage(a, loads, baseline['source'])
    comparison = report['comparison']
    a.require(type(comparison) is dict, 'Missing pair comparison')
    flags = dict(kind='qwen_long_prefill_pair_comparison',schemaVersion=1,correctnessOnly=True,
        throughputMeasurementValid=False,interprocessTransportUsed=False,physicalTransferQualified=False,
        baselineEvidenceFingerprint=baseline['referenceFingerprint'], completeStateMetadataAndDigestsExact=True,
        finalLogitMetadataAndDigestExact=True,selectedTokenExact=True,allRequestStateRetired=True,
        candidateFullLogitValuesExported=False,candidateNativeBytesComparedDirectly=False,nativeBoundaryCopies=16)
    variable = {'agreement','agreementFingerprint','frames','selectedToken','finalDigests','combinedFinalStateFingerprint'}
    a.require(set(comparison) == set(flags) | variable, 'Pair comparison schema differs')
    for key,value in flags.items(): a.exact(comparison[key], value, 'comparison.' + key)
    agreement_fp = agreement(a, comparison['agreement'], reference, baseline, loads)
    a.exact(comparison['agreementFingerprint'], agreement_fp, 'agreement fingerprint')
    identities = [identity(a, rank, load, baseline) for rank,load in enumerate(loads)]
    headers = check_frames(a, comparison['frames'], reference, baseline, loads, identities, agreement_fp)
    a.exact(comparison['selectedToken'], token(identities[1], baseline,
        reference['execution']['request']['steps'][-1]['frame']), 'actual native selected token')
    final_state = check_finals(a, comparison['finalDigests'], reference, baseline, loads, identities, agreement_fp)
    a.exact(comparison['combinedFinalStateFingerprint'], final_state, 'combined final state')
    return dict(status='passed',scope='registered9b_8192_chunk512_output1_one_process_pair',
        referenceFingerprint=baseline['referenceFingerprint'],agreementFingerprint=agreement_fp,
        promptFileSHA256=expected_prompt_sha256,arithmeticEnvironmentSHA256=baseline['arithmeticEnvironmentSHA256'],
        completedFrames=16,stageCommits=32,canonicalTensors=inventory['canonicalTensors'],
        activeTensorBytes=inventory['activeTensorBytes'],inertTensorBytes=inventory['inertTensorBytes'],
        reconstructedCanonicalEnvelopeHashes=headers,finalStateComponents=72,stageStateComponents=[36,36],
        stageLogicalStateBytes=[159973392,159973392],finalStateLogicalBytes=319946784,finalStateSHA256=final_state,
        finalLogits=baseline['finalLogits'],selectedTokenID=baseline['argmaxTokenID'],
        baselineMaximumTieCount=baseline['maximumTieCount'],candidateMaximumTieCountComputed=False,
        candidateNativeLogitBytesCompared=False,candidateFullLogitValuesAvailable=False,
        stateMetadataAndDigestsMatch=True,finalLogitMetadataAndDigestMatch=True,selectedTokenMatches=True,
        throughputQualified=False,physicalTransferQualified=False,interprocessTransportUsed=False,
        independentModelForwardPerformed=False,allocatorObservationsAreNotRSS=True,
        modelAndRequestReleaseAreSourceBoundNativeAssertions=True,
        limitations=[
            'Only the nested baseline exports values: its BF16 row is reconstructed by the reference oracle; the candidate is metadata/SHA-only.',
            'All state metadata/digests match the baseline; only baseline Int32 offsets are independently reconstructed, not the64 numerical state components.',
            'Envelope hashes are reconstructed from canonical recorded metadata; residual payload hashes remain opaque and no wire bytes or physical transfer are observed.',
            'The source tensor manifest hash is a coherent opaque loader commitment. Active/inert inventories, byte conservation and plan controls are independently checked; artifact/source/runtime provenance remains external.',
            'Native execution, early environment, owned residual copies, commits and weak release remain source-bound assertions; no timing or model-quality gain is qualified.'])


def validate(a, stdout_path, prompt_path, expected_prompt_sha256):
    pins = a.verify_pins()
    raw = a.read_bounded(stdout_path, MAX_STDOUT); prompt = a.read_bounded(prompt_path, a.MAX_PROMPT)
    result = check_pair(a, parse_rows(a, raw), prompt, expected_prompt_sha256)
    a.require(raw == a.read_bounded(stdout_path, MAX_STDOUT) and prompt == a.read_bounded(prompt_path, a.MAX_PROMPT),
              'Pair validation input changed while reading')
    a.require(a.verify_pins() == pins, 'Frozen reference dependency changed')
    result.update(stdoutSHA256=a.sha(raw),stdoutByteCount=len(raw),promptByteCount=len(prompt),
                  frozenInputsUnchanged=True,frozenReferenceDependencyPins=pins)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stdout',type=Path);parser.add_argument('prompt',type=Path);parser.add_argument('prompt_sha256')
    parser.add_argument('--reference-oracle',type=Path,required=True)
    parser.add_argument('--expected-reference-oracle-sha256',required=True)
    args = parser.parse_args()
    a = load_reference_oracle(args.reference_oracle,args.expected_reference_oracle_sha256)
    result = validate(a,args.stdout,args.prompt,args.prompt_sha256)
    a.require(a.sha(args.reference_oracle.read_bytes()) == args.expected_reference_oracle_sha256,
              'Reference-oracle source changed during audit')
    result['referenceOracleSHA256'] = args.expected_reference_oracle_sha256
    print(json.dumps(result,indent=2,sort_keys=True,allow_nan=False))


if __name__ == '__main__': main()
