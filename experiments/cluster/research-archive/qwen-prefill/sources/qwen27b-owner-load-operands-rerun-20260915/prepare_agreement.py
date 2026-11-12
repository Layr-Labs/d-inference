"""Run the existing corrected prospective preparer against the new actual build identity."""
from pathlib import Path
import json
import os
import subprocess
import sys
import time
from assemble import BASE, ROOT, OLD, pin, write


def main():
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    old = json.loads((OLD / 'provenance/expected-agreement-prepare-receipt.json').read_bytes())
    preparer = ROOT / 'registered-generation-preparer-recheck-correction-20260915'
    comparator = ROOT / 'registered-generation-numerical-audit-draft-20260915'
    assert pin(preparer / 'manifest.json')['sha256'] == old['preparerManifestSHA256']
    assert pin(comparator / 'manifest.json')['sha256'] == old['comparatorManifestSHA256']
    previous = json.loads((OLD / 'expected-agreement.json').read_bytes())
    argv = [sys.executable, '-B', str(preparer / 'proposed/prepare_expected.py')]
    for role, name in [('request', 'inputs/request.json'), ('plan', 'provenance/recording-metadata.json'),
                       ('prompt', 'inputs/prompt.ids.json')]:
        argv += ['--' + role, str(BASE / name), '--' + role + '-sha256', pin(BASE / name)['sha256']]
    argv += ['--epoch', lineage['newEpoch'], '--storage-commitment-sha256', previous['storageCommitmentSHA256'],
             '--numerical-policy-sha256', previous['numericalPolicySHA256'], '--output', str(BASE / 'expected-agreement.json')]
    started = time.monotonic()
    result = subprocess.run(argv, env=dict(os.environ, PYTHONPATH=str(comparator)), capture_output=True, timeout=60)
    (BASE / 'provenance/agreement-preparer.stdout').write_bytes(result.stdout)
    (BASE / 'provenance/agreement-preparer.stderr').write_bytes(result.stderr)
    assert result.returncode == 0 and not result.stderr
    expected = dict(previous, membershipEpoch=lineage['newEpoch'], rankBuildSHA256=[lineage['nativeBinarySHA256']] * 2)
    assert json.loads((BASE / 'expected-agreement.json').read_bytes()) == expected
    receipt = dict(schema='qwen27b_operand_diagnostic_expected_agreement_v1', argv=argv,
        environmentOverrides=dict(PYTHONPATH=str(comparator)), exitCode=result.returncode,
        elapsedSeconds=time.monotonic() - started, expectedAgreement=pin(BASE / 'expected-agreement.json'),
        changedAgreementFields=['membershipEpoch', 'rankBuildSHA256'],
        preparerManifest=pin(preparer / 'manifest.json'), comparatorManifest=pin(comparator / 'manifest.json'),
        inputs=[pin(BASE / name) for name in ['inputs/request.json', 'provenance/recording-metadata.json', 'inputs/prompt.ids.json']],
        candidateOrReferenceOutputsRead=False, compilerModelNativeOrRemoteExecuted=False)
    write('provenance/expected-agreement-prepare-receipt.json', receipt)
    gates = json.loads((OLD / 'comparison-gates.json').read_bytes())
    gates.update(expectedAgreement=pin(BASE / 'expected-agreement.json'), membershipEpoch=lineage['newEpoch'],
        nativeBinarySHA256=lineage['nativeBinarySHA256'], preparedAgreementReceipt=pin(BASE / 'provenance/expected-agreement-prepare-receipt.json'),
        registeredPlan=pin(BASE / 'provenance/recording-metadata.json'), request=pin(BASE / 'inputs/request.json'),
        prompt=pin(BASE / 'inputs/prompt.ids.json'),
        expectedAgreementPreparation='Unchanged corrected preparer rerun for fresh epoch and actual new native build SHA.',
        sourceIdentityPreservation='All source files except load-refusal observations remain byte-exact; no storage or numerical declaration changed.')
    write('comparison-gates.json', gates)
    print(json.dumps(dict(prepared=True, expectedAgreementSHA256=pin(BASE / 'expected-agreement.json')['sha256'])))


if __name__ == '__main__':
    main()
