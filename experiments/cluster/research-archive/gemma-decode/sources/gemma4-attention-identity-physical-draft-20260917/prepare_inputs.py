"""After actual corrected build: create fresh source, describe and binding only."""
import argparse, hashlib, json, shutil, sys, uuid
from pathlib import Path
from check_process import run_owned

BASE = Path(__file__).resolve().parent
CORRECTION = BASE.parent / 'gemma4-attention-identity-correction-20260917'
DRIVER = 'd88473104ae45164e81f4e55a1722015ae1fed81b82677af31eaef7e48c86821'
OLD_BUILD = BASE.parent / 'gemma4-short-correctness-draft-20260916/build'
PROMPT = BASE.parent / 'gemma4-short-correctness-root-review-20260916/actual-inputs-1/prompt-1'
OUTPUT = BASE / 'actual-inputs-1'

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True); stream.write('\n')
def check_manifest(root, expected):
    if sha(root / 'manifest.json') != expected: raise ValueError('Source manifest changed')
    value = json.loads((root / 'manifest.json').read_bytes())
    for row in value.get('members', value.get('files', [])):
        path = root / row['path']
        if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
            raise ValueError('Source member changed: ' + str(path))

def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--source-sha256', required=True)
    parser.add_argument('--build-receipt-sha256', required=True)
    args = parser.parse_args()
    check_manifest(BASE, args.source_sha256); check_manifest(CORRECTION, DRIVER)
    receipt_path = CORRECTION / 'native-1/receipt.json'
    if sha(receipt_path) != args.build_receipt_sha256: raise ValueError('Root-selected build receipt changed')
    build = json.loads(receipt_path.read_bytes())
    if build['status'] != 'passed' or build['before'] != build['after'] or build['before'] != dict(sources=3127, dependencies=8755):
        raise ValueError('Corrected source/build stability is incomplete')
    if build['nativeModelExecuted'] or build['remoteExecuted'] or len(build['steps']) != 5:
        raise ValueError('Wrong build qualification scope')
    if any(x.get('exitCode') != 0 or not x.get('reaped') or not x.get('groupAbsent') for x in build['steps']):
        raise ValueError('Build child retirement is incomplete')
    native = Path(build['binary']['path'])
    if sha(native) != build['binary']['sha256'] or native.stat().st_size != build['binary']['bytes']:
        raise ValueError('Actual corrected native changed')
    source_snapshot = CORRECTION / 'preparation/source-snapshot.json'
    dependency_snapshot = OLD_BUILD / 'dependency-snapshot-1.json'
    for key, path in [('sourceSnapshotSHA256', source_snapshot), ('dependencySnapshotSHA256', dependency_snapshot)]:
        if sha(path) != build[key]: raise ValueError('Actual corrected build snapshot changed')
    # Compare metadata inventories to the frozen correction's exact projection;
    # this does not rehash or materialize the large workspace/dependency tree.
    sys.path.insert(0, str(CORRECTION))
    from common import expected
    if json.loads(source_snapshot.read_bytes())['members'] != expected(): raise ValueError('Corrected source projection differs')
    identity = json.loads((CORRECTION / 'native-1/identity.stdout').read_bytes())
    if identity != dict(accepted=3, refused=5, actualTwoPhaseProbe=True, actualGeometryInitializer=True,
            cpuArraysExecuted=True, gpuExecuted=False, modelConstructed=False, payloadRead=False):
        raise ValueError('Actual CPU identity control differs')
    if sha(PROMPT / 'prompt.ids.json') != '4def99e2d08fa11ef6a3d655ce6252aada6a39c018b17a8884cf08c52733787d' or sha(PROMPT / 'prompt-receipt.json') != '44ceff835df296ba774e70b23b67884a71dae87001bc7de3ea53e8a048331b9d':
        raise ValueError('Original tokenizer-backed32 prompt evidence changed')
    OUTPUT.mkdir(mode=0o700)
    record = dict(status='failed', templateManifestSHA256=args.source_sha256,
        correctedDriverManifestSHA256=DRIVER, buildReceiptSHA256=args.build_receipt_sha256,
        modelOrGPUExecuted=False, remoteExecuted=False, steps=[])
    try:
        source = OUTPUT / 'source'; source.mkdir(mode=0o700)
        template = json.loads((BASE / 'source-template.json').read_bytes())['files']
        for row in template:
            original = BASE / 'source' / row['path']; target = source / row['path']
            if sha(original) != row['sha256']: raise ValueError('Template source changed')
            target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(original, target)
        reference = dict(schema='gemma_short_actual_native_build_reference_v1',
            driverManifestSHA256=DRIVER, originalDriverManifestSHA256='3803a23ef63b93ae7fbfdcf6a52b7818e4c8e5a14c36c90b9adb82f4a7afcdf2',
            nativeSHA256=build['binary']['sha256'], nativeBytes=build['binary']['bytes'],
            buildReceiptSHA256=args.build_receipt_sha256, sourceSnapshotSHA256=build['sourceSnapshotSHA256'],
            dependencySnapshotSHA256=build['dependencySnapshotSHA256'], sourceFiles=3127, dependencyFiles=8755,
            identityControlSHA256=sha(CORRECTION / 'native-1/identity.stdout'), actualCorrectedBuildProvidedByRoot=True)
        # Replace only the non-executable placeholder in the newly created copy.
        (source / 'package/native-build-reference.json').write_text(json.dumps(reference, indent=2, sort_keys=True) + '\n')
        members = [dict(path=row['path'], bytes=(source / row['path']).stat().st_size,
            sha256=sha(source / row['path'])) for row in template]
        save(source / 'manifest.json', dict(schema='gemma_short_corrected_bound_source_v1', files=members))
        record['sourceManifestSHA256'] = sha(source / 'manifest.json')
        metadata = BASE.parent.parent / 'd-inference/libs/darkbloom-cluster/Tests/StageMetadataChecks/Inputs'
        for row in json.loads((source / 'metadata-controls.json').read_bytes()):
            if sha(metadata / row['path']) != row['sha256']: raise ValueError('Captured model metadata changed')
        job = dict(schema='gemma4_short_native_check_v1', mode='full',
            modelDirectory='/Users/developer/DarkbloomDev/models/Gemma4-26B', metadataDirectory=str(metadata),
            promptFile=str(PROMPT / 'prompt.ids.json'), promptFileSHA256=sha(PROMPT / 'prompt.ids.json'),
            outputDirectory=str(OUTPUT / 'prospective-sidecars'), requestID=str(uuid.uuid4()), membershipEpoch=str(uuid.uuid4()),
            buildIdentitySHA256=build['binary']['sha256'], residualDType='bfloat16', timeoutSeconds=300)
        save(OUTPUT / 'described-job.json', job)
        record['steps'].append(run_owned([str(native), '--describe', str(OUTPUT / 'described-job.json')], OUTPUT, 'describe', 10))
        refs = dict(buildReceipt=receipt_path, sourceSnapshot=source_snapshot, dependencySnapshot=dependency_snapshot,
            describeReceipt=OUTPUT / 'describe.json', expected=OUTPUT / 'describe.stdout',
            prompt=PROMPT / 'prompt.ids.json', promptReceipt=PROMPT / 'prompt-receipt.json', jobTemplate=OUTPUT / 'described-job.json')
        packet = {key: dict(path=str(path), sha256=sha(path)) for key, path in refs.items()}
        packet.update(schema='gemma_short_root_build_inputs_v1', metadataDirectory=str(metadata)); save(OUTPUT / 'inputs.json', packet)
        record['steps'].append(run_owned(['/usr/bin/python3', '-B', str(source / 'bind_build.py'),
            '--inputs', str(OUTPUT / 'inputs.json'), '--inputs-sha256', sha(OUTPUT / 'inputs.json'),
            '--output', str(OUTPUT / 'bound')], OUTPUT, 'bind', 30))
        check_manifest(BASE, args.source_sha256); check_manifest(source, record['sourceManifestSHA256'])
        if sha(native) != build['binary']['sha256']: raise ValueError('Native changed while binding')
        record.update(status='passed', bindingReceiptSHA256=sha(OUTPUT / 'bound/binding-receipt.json'))
    finally:
        save(OUTPUT / 'receipt.json', record)
    print(json.dumps(dict(status='passed', prepared=str(OUTPUT), receiptSHA256=sha(OUTPUT / 'receipt.json'))))

if __name__ == '__main__': main()
