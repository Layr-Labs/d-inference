"""One incremental jobs2 build, model-free controls, and preserved terminal proof."""
import json, re, sys
from common import BASE, OLD, WORKSPACE, SCRATCH, BINARY, sha, verify
from check_process import run_owned

def main():
    if len(sys.argv) != 2 or not re.fullmatch(r'native-[1-9][0-9]*', sys.argv[1]):
        raise ValueError('One fresh native-N attempt required')
    if json.loads((BASE / 'preparation/receipt.json').read_bytes())['status'] != 'passed':
        raise ValueError('Correction preparation is incomplete')
    out = BASE / sys.argv[1]; out.mkdir(mode=0o700)
    receipt = dict(status='started', steps=[], nativeModelExecuted=False, remoteExecuted=False,
        sourceSnapshotSHA256=sha(BASE / 'preparation/source-snapshot.json'),
        dependencySnapshotSHA256=sha(OLD / 'dependency-snapshot-1.json'))
    try:
        receipt['before'] = verify(True)
        command = ['swift', 'build', '--package-path', str(WORKSPACE / 'libs/darkbloom-cluster-worker'),
            '--scratch-path', str(SCRATCH), '-c', 'release', '--jobs', '2', '--disable-automatic-resolution',
            '--skip-update', '--disable-build-manifest-caching', '--triple', 'arm64-apple-macosx26.2',
            '-Xcc', '-target', '-Xcc', 'arm64-apple-macosx26.2', '--product', 'GemmaShortCorrectnessCheck']
        receipt['steps'].append(run_owned(command, out, 'build', 900)); verify(True)
        receipt['steps'].append(run_owned(['xcrun', 'vtool', '-show-build', str(BINARY)], out, 'version', 10))
        version = (out / 'version.stdout').read_text()
        if version.count('LC_BUILD_VERSION') != 1 or 'platform MACOS' not in version or not any(
                line.split() == ['minos', '26.2'] for line in version.splitlines()):
            raise ValueError('Native deployment target differs')
        receipt['steps'].append(run_owned([str(BINARY), '--check-attention-identity', 'cpu'], out, 'identity', 15))
        wanted = dict(accepted=3, refused=5, actualTwoPhaseProbe=True, actualGeometryInitializer=True,
            cpuArraysExecuted=True, gpuExecuted=False, modelConstructed=False, payloadRead=False)
        if json.loads((out / 'identity.stdout').read_bytes()) != wanted: raise ValueError('Identity controls differ')
        receipt['steps'].append(run_owned([str(BINARY), '--check-local-fixtures', str(out / 'local-fixtures')], out, 'local', 10))
        if json.loads((out / 'local.stdout').read_bytes()) != dict(accepted=7, refused=15,
                nativeExecuted=False, modelConstructed=False, payloadRead=False):
            raise ValueError('Existing local controls differ')
        receipt['steps'].append(run_owned([str(BINARY), '--check-arguments', str(OLD / 'arguments-job.json')], out, 'arguments', 10))
        argument = json.loads((out / 'arguments.stdout').read_bytes())
        if not argument['metadataOnly'] or argument['actualPayloadLoaded'] or argument['runtimeExecutionAuthorized'] or argument['cut'] != 10:
            raise ValueError('Existing pure argument control differs')
        if any((out / (name + '.stderr')).stat().st_size for name in ['identity', 'local', 'arguments']):
            raise ValueError('Model-free controls emitted stderr')
        receipt['binary'] = dict(path=str(BINARY), bytes=BINARY.stat().st_size, sha256=sha(BINARY))
        receipt['resources'] = []
        for row in json.loads((OLD / 'resource-controls.json').read_bytes())['files']:
            path = BINARY.parent / row['path']
            if path.is_symlink() or path.stat().st_size != row['bytes'] or sha(path) != row['sha256']:
                raise ValueError('Unchanged native resource closure differs')
            receipt['resources'].append(dict(path=str(path), bytes=row['bytes'], sha256=row['sha256']))
        receipt['status'] = 'passed'
    except BaseException as error:
        receipt['status'] = 'failed'; receipt['failure'] = type(error).__name__ + ': ' + str(error); raise
    finally:
        try: receipt['after'] = verify(True)
        except BaseException as error:
            receipt['status'] = 'failed'; receipt['sourceRecheckFailure'] = str(error)
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    if receipt['status'] != 'passed': raise ValueError('Source recheck failed')
    print('Incremental Gemma build and CPU identity controls PASS')

if __name__ == '__main__': main()
