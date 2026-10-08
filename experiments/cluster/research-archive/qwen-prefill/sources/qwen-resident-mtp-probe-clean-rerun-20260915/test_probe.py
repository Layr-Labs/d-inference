"""Fabricated value/IO refusals; never claims model execution."""
import copy
import json
import tempfile
import subprocess
import sys
import unittest
from pathlib import Path
from probe_values import *
from probe_validation import context, compare
from probe_io import read_file, prospective

BASE = Path(__file__).resolve().parent


def fixture(draft=23):
    request = parse_json((BASE / 'request.json').read_bytes())
    expected = parse_json((BASE / 'configuration/expected-agreement.json').read_bytes())
    config_sha = digest((BASE / 'configuration/controller.json').read_bytes())
    ctx = context(request); agreed = agreement(expected, ctx)
    probe = digest(canonical(['registered-qwen35-9b-single-unaccepted-proposal-v1', agreed,
        'head-rank1', 'replicated-input-embedding', 'depth1', 'ordinary-target-seed-decode']))
    candidates = []
    for rank in (0, 1):
        identity = dict(stageIndex=rank, requestFingerprint=ctx['fingerprint'], artifactAggregateSHA256=ARTIFACT,
            storageCommitmentSHA256=expected['storageCommitmentSHA256'], bf16ConversionEnabled=True,
            sourceConfigurationSHA256=CONFIG, constructionConfigurationSHA256=CONSTRUCTIONS[rank],
            planFingerprint=PLAN, stageFingerprint=STAGES[rank], activationDType='bfloat16')
        execution = dict(schema='qwen_stage_generation_result_v1', agreementFingerprint=agreed,
            membershipEpoch=expected['membershipEpoch'], identity=identity, selectedTokenIDs=[17, 19],
            tokenChainSHA256='2' * 64, completedFrames=3, committedTokens=33, finishReason='length',
            bothRequestStatesRetired=True, modelRemainsResident=True, mtpEnabled=False,
            physicalTransferQualified=False, independentNumericalComparisonPerformed=False, externalTTFTMeasured=False)
        value = dict(schema='qwen_stage_single_unaccepted_mtp_proposal_v1', rank=rank,
            probeReadinessFingerprint=probe, execution=execution, targetSecondToken=19,
            proposalWasConsumedAsTargetInput=False, speculativeAcceptanceImplemented=False)
        if rank == 1:
            value.update(proposal=dict(requestID=request['requestID'].upper(), roundID='218AF922-4AA1-442B-97A8-E59271968F3D',
                agreementFingerprint=agreed, committedTargetInputs=32, seedTokenID=17,
                previousTokenChainSHA256='1' * 64, proposedTokenID=draft, draftDepth=1, accepted=False),
                assistantInputsBeforeProposal=31, assistantInputsAfterProposal=32,
                assistantRequestReleased=True, proposalMatchesTarget=draft == 19)
        candidates.append(value)
    records = [dict(schema='owner_qualification_started_v1', configurationSHA256=config_sha, cpuQualification=False,
        membershipEpoch=expected['membershipEpoch'], requestID=request['requestID'], promptCount=32, outputCount=2,
        performanceQualification=False, numericalQualification=False),
        dict(schema='owner_qualification_result_v1', configurationSHA256=config_sha, cpuQualification=False, completed=True,
        tokenIDs=[17, 19], performanceQualification=False, numericalQualification=False,
        nativeCleanupObserved=[True, True], ownerDeviceLeaseReleasedObserved=[True, True], endpointDiagnosticsBase64=['', ''],
        journalRelease='Authenticated owner acknowledgment; separate remote journal/process observation remains useful',
        elapsedControllerNanoseconds=10_000_000, finishReason='length')]
    return request, expected, candidates, records, config_sha


class ProbeChecks(unittest.TestCase):
    def test_proposal_mismatch_is_valid_and_unaccepted(self):
        result = compare(*fixture())
        self.assertFalse(result['proposalMatchesTarget']); self.assertFalse(result['speculativeAcceptanceImplemented'])
        self.assertFalse(result['independentTargetNumericalComparisonPerformed'])
    def test_matching_proposal_does_not_enable_acceptance(self):
        result = compare(*fixture(19)); self.assertTrue(result['proposalMatchesTarget'])
        self.assertFalse(result['speculativeAcceptanceImplemented'])
    def test_bad_native_fields(self):
        cases = [('accepted', True), ('seedTokenID', 19), ('committedTargetInputs', 31), ('draftDepth', 2),
                 ('proposedTokenID', True), ('requestID', '00000000-0000-0000-0000-000000000000'),
                 ('roundID', '00000000-0000-0000-0000-000000000000'), ('previousTokenChainSHA256', '2' * 64)]
        for key, value in cases:
            with self.subTest(key=key), self.assertRaises(ValueError):
                data = fixture(); data[2][1]['proposal'][key] = value; compare(*data)
    def test_history_retirement_and_target_state(self):
        for key, value in [('assistantInputsBeforeProposal', 32), ('assistantInputsAfterProposal', 33),
                           ('assistantRequestReleased', False), ('proposalMatchesTarget', True),
                           ('proposalWasConsumedAsTargetInput', True), ('speculativeAcceptanceImplemented', True)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                data = fixture(); data[2][1][key] = value; compare(*data)
    def test_execution_rejections(self):
        for key, value in [('completedFrames', 4), ('committedTokens', 34), ('mtpEnabled', True),
                           ('finishReason', 'eos'), ('selectedTokenIDs', [17, 23]), ('tokenChainSHA256', '3' * 64)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                data = fixture(); data[2][1]['execution'][key] = value; compare(*data)
    def test_rank0_cannot_own_assistant(self):
        data = fixture(); data[2][0]['assistantRequestReleased'] = True
        with self.assertRaises(ValueError): compare(*data)
    def test_missing_owner_proof(self):
        for key in ('nativeCleanupObserved', 'ownerDeviceLeaseReleasedObserved'):
            data = fixture(); data[3][1][key] = [True, False]
            with self.subTest(key=key), self.assertRaises(ValueError): compare(*data)
    def test_incomplete_controller(self):
        data = fixture(); data[3].pop()
        with self.assertRaises(ValueError): compare(*data)
    def test_duplicate_nonfinite_and_boolean_counts(self):
        for raw in ('{"a":1,"a":2}', '{"a":NaN}'):
            with self.assertRaises(ValueError): parse_json(raw)
        data = fixture(); data[3][1]['elapsedControllerNanoseconds'] = True
        with self.assertRaises(ValueError): compare(*data)
    def test_bounded_regular_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'data'; path.write_bytes(b'123')
            self.assertEqual(read_file(path, 3), b'123')
            with self.assertRaises(ValueError): read_file(path, 2)
            link = Path(directory) / 'link'; link.symlink_to(path)
            with self.assertRaises(OSError): read_file(link, 3)
    def test_actual_cli_success_and_retained_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory); data = fixture()
            for rank in (0, 1):
                (path / f'rank{rank}.json').write_text(json.dumps(data[2][rank]))
            (path / 'controller.jsonl').write_text(''.join(json.dumps(x) + '\n' for x in data[3]))
            command = [sys.executable, '-B', str(BASE / 'validate_probe.py'), '--rank0', str(path/'rank0.json'),
                       '--rank1', str(path/'rank1.json'), '--controller', str(path/'controller.jsonl')]
            good = subprocess.run(command + ['--output', str(path/'good.json')], capture_output=True, timeout=10)
            self.assertEqual(good.returncode, 0); self.assertEqual(good.stderr, b'')
            data[2][1]['proposal']['accepted'] = True
            (path/'rank1.json').write_text(json.dumps(data[2][1]))
            bad = subprocess.run(command + ['--output', str(path/'bad.json')], capture_output=True, timeout=10)
            self.assertEqual(bad.returncode, 1); self.assertEqual(bad.stderr, b'')
            self.assertEqual(json.loads((path/'bad.json').read_bytes())['status'], 'failed')
    def test_prospective_pin_before_candidate(self):
        policy, _, _ = prospective(BASE)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            for name in policy['files']:
                (target / name).parent.mkdir(parents=True, exist_ok=True)
                (target / name).write_bytes((BASE / name).read_bytes())
            (target / 'policy.json').write_bytes((BASE / 'policy.json').read_bytes())
            (target / 'request.json').write_bytes(b'{}')
            with self.assertRaises(ValueError): prospective(target)


if __name__ == '__main__': unittest.main()
