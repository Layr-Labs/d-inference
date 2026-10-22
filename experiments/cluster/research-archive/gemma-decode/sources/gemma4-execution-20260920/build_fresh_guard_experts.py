"""Compose reviewed guard consolidation and separately bounded expert extension."""
import json
from pathlib import Path
import subprocess

from build_experts import ROOT, WORK, build, digest, verify


def main():
    prior_path = ROOT / 'build/applied-guard-metrics.json'
    assert digest(prior_path) == '386403c0125d7b5a14165f170635b1dc6e70e83173965d9aac7ee981a872d6a7'
    prior = json.loads(prior_path.read_bytes())
    for row in prior['files']:
        verify(WORK / row['path'], row)
    for name, kind in [('p128-cut8-c64-serial-v5', 'solo'), ('p128-cut8-c64-serial-v5', 'pair'),
                       ('p128-cut8-c64-overlap-v5', 'pair')]:
        report = json.loads((ROOT / 'cases' / name / kind / 'guard-analysis.json').read_bytes())
        assert report['status'] == 'passed' and report['observationPolicy'] == 'repeated'
        assert report['nativeSHA256'] == 'f3676c3ab0e41c25552d2aead70f39b68bc9e627db67368fe3fffd99a2cde7b0'
    assert json.loads((ROOT / 'cases/p128-cut8-c64-overlap-v5/comparison-overlap.json').read_bytes())['status'] == 'passed'
    draft = ROOT.parent / 'gemma4-benchmark-fresh-guard-20260920'
    assert digest(draft / 'source-inputs.json') == '3a51c3b0d6d046bcd75ab7302b6942899db825deee867ef0859424f40ff59aa7'
    fresh = json.loads((draft / 'source-inputs.json').read_bytes())
    for row in fresh['files'] + fresh['dependencies']:
        path = Path(row['path']);verify(path if path.is_absolute() else draft / path, row)
    entries = [(draft, row) for row in fresh['entries']]
    packages = []
    for name, manifest_sha, integration_sha in [
        ('gemma4-expert-prefill-bound-20260920', '96b09205616dc075d0efb09c6962a630f7e88ba14ee8a7b76e6613fe34b44a06',
         '13b9d67c161a84c58dda2472d4a61b6019376d132aebac7bae6d47b517d4bc6e'),
        ('gemma4-expert-prefill-description-20260920', 'ed9ee5cfa7e0357d6f003c9553204425d40c6ac8fabaf5656dcdda0ede13748e',
         '59115464bb9906de761210243baf9dfa044a2104daf3528eafcf61966132490c'),
    ]:
        source = ROOT.parent / name
        assert digest(source / 'manifest.json') == manifest_sha
        assert digest(source / 'integration.json') == integration_sha
        for row in json.loads((source / 'manifest.json').read_bytes())['files']:
            verify(source / row['path'], row)
        entries.extend((source, row) for row in json.loads((source / 'integration.json').read_bytes())['entries'])
        packages.append(dict(name=name, manifestSHA256=manifest_sha, integrationSHA256=integration_sha))
    for source, row in entries:
        target = WORK / row['destination']
        if row['before'] is None:
            assert not target.exists(), target
        else:
            verify(target, row['before'])
        verify(source / row['source'], row['after'])
    assert len({row['destination'] for _, row in entries}) == len(entries) == 15
    preserve = ROOT / 'build/before-fresh-guard-expert-prefill'
    preserve.mkdir(mode=0o700)
    binary_dir = WORK / 'libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release'
    originals = {'GemmaResidentBenchmark': 'f3676c3ab0e41c25552d2aead70f39b68bc9e627db67368fe3fffd99a2cde7b0',
                 'GemmaExpertAxisCheck': '5e82a28d03beb715aa821bfb44389c43a96689d4ddfc57d299f6f7f7f1588943',
                 'GemmaExpertRDMACheck': '0df9ab04f65f305c25c732b9cc4e3572c9587e0de71de2bbcb7ca89add744ef0'}
    for name, wanted in originals.items():
        source = binary_dir / name;assert digest(source) == wanted
        subprocess.run(['/bin/cp', '-c', str(source), str(preserve / name)], check=True)
        assert digest(preserve / name) == wanted
    for source, row in entries:
        target = WORK / row['destination']
        if target.exists():
            backup = preserve / row['destination'];backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_bytes(target.read_bytes())
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((source / row['source']).read_bytes());verify(target, row['after'])
    paths = {WORK / row['path'] for row in prior['files']} | {WORK / row['destination'] for _, row in entries}
    sources = dict(priorSourcesSHA256=digest(prior_path),
        sourcePackages=[dict(name='gemma4-expert-projection-policy-20260920', integrationSHA256='e9245b99cb55496bb097014b9bf253ae483cc909d45305a4fb4e0df041693b87')] + packages,
        guardMetricsSourceSHA256='84352102855784c7137546371eda5c77be427dee881a5f407d7b3c0cdf3d549c',
        freshGuardSourceSHA256=digest(draft / 'source-inputs.json'),
        files=[dict(path=str(path.relative_to(WORK)), bytes=path.stat().st_size, sha256=digest(path)) for path in sorted(paths)])
    receipt_name = 'applied-fresh-guard-expert-prefill.json'
    with (ROOT / 'build' / receipt_name).open('x') as stream:json.dump(sources, stream, indent=2)
    for product, attempt in [('GemmaResidentBenchmark', 5), ('GemmaExpertAxisCheck', 4), ('GemmaExpertRDMACheck', 3)]:
        build(product, sources, attempt=attempt, source_receipt=receipt_name)


if __name__ == '__main__':
    main()
