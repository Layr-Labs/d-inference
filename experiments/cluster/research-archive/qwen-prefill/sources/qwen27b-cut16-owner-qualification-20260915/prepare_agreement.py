"""Run the unchanged corrected preparer against the frozen prospective cut16 catalog."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from assemble import BASE, pin


def main():
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    audit = Path(lineage['comparator']['path']).parent
    assert pin(audit / 'manifest.json')['sha256'] == 'f3757094f14cc479e761b83b2a988551250bd61a9dba1797e91c3e564f29aebe'
    for row in json.loads((audit / 'manifest.json').read_bytes())['files']:
        value = pin(audit / row['path'])
        assert (value['bytes'], value['sha256']) == (row['bytes'], row['sha256'])
    identity = json.loads((BASE / 'provenance/expected-identity.json').read_bytes())
    argv = [sys.executable, '-B', str(audit / 'prepare_expected.py')]
    for role, name in [('request', 'inputs/request.json'), ('plan', 'provenance/recording-metadata.json'), ('prompt', 'inputs/prompt.ids.json')]:
        argv += ['--' + role, str(BASE / name), '--' + role + '-sha256', pin(BASE / name)['sha256']]
    argv += ['--epoch', lineage['newEpoch'], '--storage-commitment-sha256', identity['storageCommitmentSHA256'],
             '--numerical-policy-sha256', identity['arithmeticSHA256'], '--output', str(BASE / 'expected-agreement.json')]
    began = time.monotonic()
    result = subprocess.run(argv, capture_output=True, timeout=60, env=dict(os.environ, PYTHONPATH=str(audit)))
    (BASE / 'provenance/preparer.stdout').write_bytes(result.stdout)
    (BASE / 'provenance/preparer.stderr').write_bytes(result.stderr)
    assert result.returncode == 0 and not result.stderr
    receipt = dict(argv=argv, exitCode=result.returncode, elapsedSeconds=time.monotonic() - began,
        comparatorManifest=pin(audit / 'manifest.json'), expectedAgreement=pin(BASE / 'expected-agreement.json'),
        sourceIdentity=pin(BASE / 'provenance/expected-identity.json'), candidateOrReferenceOutputsRead=False,
        nativeCompilerModelOrRemoteExecuted=False)
    with (BASE / 'provenance/expected-agreement-prepare-receipt.json').open('x') as stream:
        json.dump(receipt, stream, indent=2); stream.write('\n')
    print(json.dumps(dict(prepared=True, expectedAgreement=receipt['expectedAgreement'])))


if __name__ == '__main__':
    main()
