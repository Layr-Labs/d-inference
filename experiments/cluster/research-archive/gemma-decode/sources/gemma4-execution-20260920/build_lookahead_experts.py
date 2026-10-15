"""Apply reviewed, byte-bound successors in the disposable native workspace."""
from pathlib import Path
import json
import subprocess

from build_experts import ROOT, WORK, digest, verify, build


def main():
    baseline = json.loads((ROOT / 'build/applied-experts-2.json').read_bytes())
    for row in baseline['files']:
        verify(WORK / row['path'], row)
    packages = [
        ('gemma4-prefill-lookahead-20260920', 'e50c7500e237ec25d2f2ce90dc8253988afc4fad76f5e63e7ebf48eebd150989'),
        ('gemma4-expert-projection-policy-20260920', 'e9245b99cb55496bb097014b9bf253ae483cc909d45305a4fb4e0df041693b87'),
    ]
    entries = []
    for name, wanted in packages:
        source = ROOT.parent / name
        assert digest(source / 'integration.json') == wanted
        manifest = json.loads((source / 'integration.json').read_bytes())
        for row in manifest['files']:
            verify(source / row['path'], row)
        for row in manifest['unchangedDependencies']:
            verify(Path(row['path']), row)
        for row in manifest['entries']:
            target = WORK / row['destination']
            if row['before'] is None:
                assert not target.exists(), target
            else:
                verify(target, row['before'])
            verify(source / row['source'], row['after'])
            entries.append((source / row['source'], target, row['after']))
    unread = ROOT.parent / 'gemma4-resident-unread-staging-20260920'
    assert digest(unread / 'manifest.json') == '998291d4cdeebe10a3f5a1c3a4ee37983308fd7e92cd8b4b7ee8603c3d385242'
    for row in json.loads((unread / 'manifest.json').read_bytes())['files']:
        verify(unread / row['path'], row)
    composition = json.loads((unread / 'lookahead-composition.json').read_bytes())
    runtime = WORK / 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime'
    assert not (runtime / 'Gemma4BenchmarkUnreadStaging.swift').exists()
    preserved = ROOT / 'build/before-lookahead-experts'
    preserved.mkdir(mode=0o700)
    binary_dir = WORK / 'libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release'
    for name in ['GemmaResidentBenchmark', 'GemmaExpertAxisCheck', 'GemmaExpertRDMACheck']:
        source = binary_dir / name
        subprocess.run(['/bin/cp', '-c', str(source), str(preserved / name)], check=True)
        assert digest(source) == digest(preserved / name)
    for source, target, after in entries:
        if target.exists():
            backup = preserved / target.relative_to(WORK)
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_bytes(target.read_bytes())
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
        verify(target, after)
    owner = runtime / 'Gemma4BenchmarkResourceOwner.swift'
    assert digest(owner) == composition['beforeSHA256']
    patch = unread / composition['patch']
    subprocess.run(['/usr/bin/git', 'apply', '--check', str(patch)], cwd=WORK, check=True)
    subprocess.run(['/usr/bin/git', 'apply', str(patch)], cwd=WORK, check=True)
    assert digest(owner) == composition['afterSHA256']
    helper = runtime / 'Gemma4BenchmarkUnreadStaging.swift'
    helper.write_bytes((unread / composition['addHelper']).read_bytes())
    paths = {WORK / row['path'] for row in baseline['files']} | {target for _, target, _ in entries} | {helper}
    sources = dict(sourcePackages=[dict(name=name, integrationSHA256=wanted) for name, wanted in packages],
                   unreadManifestSHA256=digest(unread / 'manifest.json'),
                   files=[dict(path=str(path.relative_to(WORK)), bytes=path.stat().st_size, sha256=digest(path))
                          for path in sorted(paths)])
    receipt_name = 'applied-lookahead-experts.json'
    with (ROOT / 'build' / receipt_name).open('x') as stream:
        json.dump(sources, stream, indent=2)
    controls = ROOT / 'metadata-checks/projection-policy-v1'
    controls.mkdir(mode=0o700)
    draft = ROOT.parent / packages[1][0]
    commands = [
        ['/usr/bin/swiftc', '-swift-version', '6', '-warnings-as-errors', '-O', '-j', '2',
         *[str(runtime / name) for name in ['ClusterRuntimeError.swift', 'ExpertIDOwnership.swift',
                                          'ExpertDispatchPlan.swift', 'ExpertAxisProjectionPolicy.swift']],
         str(draft / 'Tests/ProjectionPolicyControls.swift'), '-o', str(controls / 'ProjectionPolicyControls')],
        [str(controls / 'ProjectionPolicyControls')],
    ]
    for index, command in enumerate(commands):
        result = subprocess.run(command, capture_output=True, timeout=60)
        (controls / f'{index}.stdout').write_bytes(result.stdout)
        (controls / f'{index}.stderr').write_bytes(result.stderr)
        print(json.dumps(dict(control=index, exitCode=result.returncode,
                              stdout=result.stdout.decode(), stderr=result.stderr.decode())), flush=True)
        assert result.returncode == 0
    for name, attempt in [('GemmaResidentBenchmark', 3), ('GemmaExpertAxisCheck', 3), ('GemmaExpertRDMACheck', 2)]:
        build(name, sources, attempt=attempt, source_receipt=receipt_name)


if __name__ == '__main__':
    main()
