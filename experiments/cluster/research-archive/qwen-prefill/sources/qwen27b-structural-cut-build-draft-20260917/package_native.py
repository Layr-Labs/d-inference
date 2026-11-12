"""Package only exact successfully built/checked binaries and matched resources."""
import json
import os
from pathlib import Path
import shutil
import sys
from native_inputs import BASE, paths, require, pin, sha, verify_prepared, write


def main():
    role, attempt = sys.argv[1:]
    require(attempt.isdecimal() and 1 <= int(attempt) <= 99, 'Successful numeric attempt required')
    spec, root, work, package, cache, binary = paths(role)
    build_path = root / ('build-' + attempt) / 'receipt.json'
    check_path = root / ('check-' + attempt) / 'receipt.json'
    build, check = json.loads(build_path.read_bytes()), json.loads(check_path.read_bytes())
    require(build.get('role') == check.get('role') == role and
            build.get('passed') is True and check.get('passed') is True and
            build['binary'] == check['binary'] == pin(binary), 'Exact successful build and CPU check required')
    require([step['name'] for step in build['steps']] == ['compile', 'vtool', 'otool'] and
            all(step.get('exitCode') == 0 and step.get('reaped') and step.get('groupAbsent') for step in build['steps']),
            'All owned compile/inspection steps must pass')
    require(all(step.get('exitCode') == step['expectedExitCode'] and step.get('reaped') and step.get('groupAbsent')
                for step in check['steps']), 'Every owned CPU check must retire as expected')
    checked = verify_prepared(role)
    checked.pop('actualSource'); checked.pop('dependencies')
    original = json.loads(Path(spec['bundleManifest']['path']).read_bytes())
    resources = {row['path']: row for row in original['files']}
    names = [binary.name, 'mlx.metallib', 'mlx-swift-lm_MLXLMCommon.bundle/pagedattention.metal']
    target = root / ('runtime-bundle-' + attempt)
    target.mkdir(mode=0o700)
    rows = []
    for name in names:
        source = binary.parent / name
        require(source.is_file() and not source.is_symlink(), 'Expected regular built bundle file')
        if name != binary.name:
            require(source.stat().st_size == resources[name]['bytes'] and sha(source) == resources[name]['sha256'], 'Matched resource differs')
        destination = target / name
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with source.open('rb') as origin, destination.open('xb') as output:
            shutil.copyfileobj(origin, output, length=1024 * 1024)
        destination.chmod(0o700 if name == binary.name else 0o600)
        require(sha(destination) == sha(source), 'Bundle copy changed')
        rows.append(dict(path=name, bytes=destination.stat().st_size, sha256=sha(destination)))
    require(pin(binary) == build['binary'], 'Built binary changed during copy')
    after = verify_prepared(role)
    after.pop('actualSource'); after.pop('dependencies')
    manifest = dict(schema='qwen27b_structural_cut_native_bundle_v1', role=role, files=rows,
        sourceCandidateSHA256='32eeb9b524b16fb2551d6faf7bd7dd1db1c84c7480287853173bdad544539121',
        buildSourceManifestSHA256=sha(BASE / 'manifest.json'), buildReceipt=pin(build_path), checkReceipt=pin(check_path),
        sourceSnapshot=pin(root / 'source-snapshot.json'), dependencySnapshot=pin(root / 'dependency-snapshot.json'),
        verification=after, nativeModelOrRemoteExecuted=False, perStageLedgerEnabled=False)
    write(target / 'bundle.json', manifest)
    print(json.dumps(dict(passed=True, role=role, bundle=pin(target / 'bundle.json'), binarySHA256=build['binary']['sha256'])), flush=True)


if __name__ == '__main__':
    os.umask(0o077)
    main()
