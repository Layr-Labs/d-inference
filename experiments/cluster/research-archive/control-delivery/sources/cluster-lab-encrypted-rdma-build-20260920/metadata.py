"""Public CPU-only contract/argument controls, never --execute or a private key."""
import hashlib
import json

from commands import run
from guards import BASE, INPUTS, fresh, pin, save_receipt, sha, write_json

GROUPS = ['local-contract', 'describe', 'check-arguments', 'wrong-identity', 'wrong-size', 'wrong-rank']
LOCAL_GROUPS = ['valid-job', 'invalid-identity', 'invalid-rank', 'invalid-size', 'invalid-rounds',
                'rank-common-transcript', 'channel-domain-separation', 'real-codec-replay']
ERROR = b'Lab authenticated RDMA component failed; retain owner receipts\n'


def description(job):
    fields = [job[key] for key in ('schema', 'identityKind', 'runID', 'payloadBytes', 'warmups',
                                 'measurements', 'timeoutSeconds', 'sourceSnapshotSHA256',
                                 'mlxArtifactSHA256', 'secretCommitmentSHA256')]
    fields += job['hostKeySHA256'] + job['nativeBuildSHA256'] + job['expectedHardware'] + job['expectedOSBuild']
    scope = hashlib.sha256('\n'.join(map(str, fields)).encode()).hexdigest()
    return dict(schema='lab_authenticated_rdma_description_v1', scopeSHA256=scope,
                payloadBytes=job['payloadBytes'], frameCeiling=max(32, job['payloadBytes']) + 40,
                modes=['raw_payload', 'raw_record_size', 'encrypted_record', 'encrypted_array'],
                warmups=3, measurements=20, maximumRecordsPerDirection=64,
                nativeAllowanceBytes=256 * 1024**2, processAllowanceBytes=512 * 1024**2,
                minimumActualFreeBytes=6 * 1024**3 + 512 * 1024**2,
                requiresAC=True, pressureLevel=1, maximumSwapBytes=0, labOnly=True,
                productMembershipEstablished=False, productRuntimeApproved=False,
                metadataOnly=True, nativeExecuted=False)


def qualify(binary, output):
    fresh(output)
    native = pin(binary)
    fixture = BASE / 'metadata-job.json'
    job = json.loads(fixture.read_bytes())
    receipt = dict(schema='lab_rdma_native_metadata_v1', passed=False, metadataOnly=True,
                   nativeSHA256=native['sha256'], nativeBytes=native['bytes'], groups=[],
                   publicFixtureSHA256=sha(fixture), gpuExecuted=False, remoteExecuted=False)
    env = ['/usr/bin/env', 'TMPDIR=/private/tmp/', str(binary)]
    try:
        run(output, receipt, GROUPS[0], env + ['--check-local'], 15, output_limit=1024**2)
        actual = json.loads((output / 'local-contract.stdout').read_bytes())
        expected = dict(schema='lab_record_local_contract_v1', passed=True, groups=LOCAL_GROUPS,
                        nativeGroupExecuted=False, publicFixtureKeyOnly=True)
        if actual != expected or (output / 'local-contract.stderr').read_bytes():
            raise ValueError('Eight real codec/contract groups differ')
        receipt['localContract'] = actual; receipt['groups'].append(GROUPS[0])
        for name in GROUPS[1:3]:
            run(output, receipt, name, env + ['--' + name, str(fixture)], 15, output_limit=1024**2)
            if json.loads((output / (name + '.stdout')).read_bytes()) != description(job) or (output / (name + '.stderr')).read_bytes():
                raise ValueError('Metadata description differs: ' + name)
            receipt['groups'].append(name)
        for name, key, value in [('wrong-identity', 'identityKind', 'verified_pair'),
                                 ('wrong-size', 'payloadBytes', 700), ('wrong-rank', 'rank', 2)]:
            changed = dict(job); changed[key] = value
            path = output / (name + '.json'); write_json(path, changed)
            run(output, receipt, name, env + ['--check-arguments', str(path)], 15,
                expected_exit=1, output_limit=1024**2)
            if (output / (name + '.stdout')).read_bytes() or (output / (name + '.stderr')).read_bytes() != ERROR:
                raise ValueError('Negative argument failure differs: ' + name)
            receipt['groups'].append(name)
        if pin(binary) != native or receipt['groups'] != GROUPS or sha(fixture) != INPUTS['authorities']['metadataFixture']['sha256']:
            raise ValueError('Metadata inputs/groups changed')
        receipt['passed'] = True
    except BaseException as error:
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        save_receipt(output / 'receipt.json', receipt)
    return dict(path=str(output / 'receipt.json'), sha256=sha(output / 'receipt.json'))
