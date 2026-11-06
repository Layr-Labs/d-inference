"""Keep retained evidence durable without populating the filesystem data cache."""
import json
from pathlib import Path
import subprocess

from build_experts import ROOT, WORK, build, digest, verify


def main():
    prior_path = ROOT / 'build/applied-fresh-guard-expert-prefill.json'
    assert digest(prior_path) == '1dd0bfaf4fb7c9425eb631bfd45bfd25c4c3b2d87b7d9e9fd330acdb40fda33e'
    prior = json.loads(prior_path.read_bytes())
    for row in prior['files']:
        verify(WORK / row['path'], row)
    name = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Gemma4BenchmarkSidecars.swift'
    target = WORK / name
    before = target.read_bytes()
    anchor = b'        try data.withUnsafeBytes { buffer in\n'
    assert before.count(anchor) == 1
    inserted = (
        b'        // Evidence is outside request timing and is read only after owner retirement.\n'
        b'        // Avoid retaining its data pages across the next measured request.\n'
        b'        // All original writes, fsync, identity checks and byte bounds remain.\n'
        b'        guard fcntl(file, F_NOCACHE, 1) == 0 else {\n'
        b'            throw ProbeError("Gemma sidecar uncached IO policy failed")\n'
        b'        }\n'
    )
    after = before.replace(anchor, inserted + anchor)
    assert after.replace(inserted, b'') == before
    preserve = ROOT / 'build/before-uncached-sidecars'
    preserve.mkdir(mode=0o700)
    (preserve / target.name).write_bytes(before)
    binary = WORK / 'libs/darkbloom-cluster-worker/.build-native-worker/arm64-apple-macosx/release/GemmaResidentBenchmark'
    assert digest(binary) == '110598d98fe332d012113ca4db05a3714e5d5dbacefcf3a1b72cf768f3ac0720'
    subprocess.run(['/bin/cp', '-c', str(binary), str(preserve / binary.name)], check=True)
    target.write_bytes(after)
    sources = dict(prior)
    sources['priorSourcesSHA256'] = digest(prior_path)
    sources['evidenceDataCachePolicy'] = 'F_NOCACHE enabled on each exclusive output fd before first write'
    sources['files'] = [dict(path=r['path'], bytes=(WORK / r['path']).stat().st_size,
                             sha256=digest(WORK / r['path'])) for r in prior['files']]
    receipt = ROOT / 'build/applied-uncached-sidecars.json'
    with receipt.open('x') as stream:
        json.dump(sources, stream, indent=2)
    build('GemmaResidentBenchmark', sources, attempt=6, source_receipt=receipt.name)


if __name__ == '__main__':
    main()
