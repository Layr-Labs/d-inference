"""Exercise actual bound native argument and C128 metadata paths, never GPU work."""
import hashlib
import json
from pathlib import Path
import subprocess
import uuid

from build_binding import verify

ROOT = Path(__file__).resolve().parent


def main():
    binding = verify()
    folder = ROOT / 'metadata-controls'
    folder.mkdir(mode=0o700)
    native = {}
    for row in binding['products']:
        p = Path(binding['binaryDirectory']) / row['product']
        assert p.stat().st_size == row['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest() == row['sha256']
        native[row['product']] = p
    rows = []

    def run(name, binary, args, accepted):
        result = subprocess.run([str(binary), *args], stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
        (folder / (name + '.stdout')).write_bytes(result.stdout)
        (folder / (name + '.stderr')).write_bytes(result.stderr)
        assert len(result.stdout) < 32768 and len(result.stderr) <= 8193
        assert result.returncode == (0 if accepted else 1)
        assert (not result.stderr) if accepted else (not result.stdout and bool(result.stderr))
        rows.append(dict(name=name, exitCode=result.returncode, expectedAccepted=accepted,
                         stdoutSHA256=hashlib.sha256(result.stdout).hexdigest(),
                         stderrSHA256=hashlib.sha256(result.stderr).hexdigest()))
        return json.loads(result.stdout) if accepted else None

    axis = native['GemmaExpertAxisCheck']
    for name, args in [('empty', []), ('unknown', ['--unknown']),
                       ('relative', ['--checkpoint', 'relative', '--layer', '0']),
                       ('layer-high', ['--checkpoint', '/fixture', '--layer', '30']),
                       ('layer-negative', ['--checkpoint', '/fixture', '--layer', '-1'])]:
        run('axis-' + name, axis, args, False)
    rdma = native['GemmaExpertRDMACheck']
    local = run('rdma-local', rdma, ['--check-local'], True)
    assert local['passed'] is True and local['nativeExecuted'] is False and local['modelPayloadRead'] is False
    assert len(local['groups']) == 7
    job = dict(schema='gemma4_expert_rdma_check_v1', modelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B',
               membershipEpoch=str(uuid.uuid4()), requestID=str(uuid.uuid4()),
               buildIdentitySHA256=next(r['sha256'] for r in binding['products'] if r['product'] == rdma.name),
               ownership='contiguous48_80', rank=0, layer=0, tokenCounts=[1, 7, 8, 9, 33, 64, 128], timeoutSeconds=300)
    job_path = folder / 'job.json'
    job_path.write_text(json.dumps(job))
    for action in ['--describe', '--check-arguments']:
        value = run('rdma' + action, rdma, [action, str(job_path)], True)
        assert value['metadataOnly'] and not value['nativeExecuted'] and not value['runtimeServingEnabled']
        assert value['maximumAssignments'] == 1024 and value['maximumTensorBytes'] == 8 * 1024**2
        assert value['extraNativeStagingBytes'] == value['extraHostStagingBytes'] == 32 * 1024**2
        assert value['tokenCounts'] == job['tokenCounts']
    for index, delta in enumerate([dict(tokenCounts=[34]), dict(tokenCounts=[129]),
                                   dict(tokenCounts=[1, 1]), dict(rank=2), dict(layer=30),
                                   dict(buildIdentitySHA256='unsigned')]):
        p = folder / ('invalid-' + str(index) + '.json')
        p.write_text(json.dumps(dict(job, **delta)))
        run('invalid-' + str(index), rdma, ['--check-arguments', str(p)], False)
    result = dict(status='passed', calls=rows, sourceBindingsSHA256=hashlib.sha256((ROOT / 'artifact-bindings.json').read_bytes()).hexdigest(),
                  localMetadataGroups=7, modelOrCollectiveOrGPUActivated=False)
    (folder / 'receipt.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(dict(status='passed', calls=len(rows), metadataGroups=7, modelOrCollectiveOrGPUActivated=False)))


if __name__ == '__main__':
    main()
