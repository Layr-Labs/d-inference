"""Freeze the existing supervisor around an actual phase-timer build."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    source = ROOT / 'harness-local-mtp-v2'
    output = ROOT / 'harness-local-mtp-profile'
    manifest = json.loads((source / 'source-inputs.json').read_bytes())
    output.mkdir(mode=0o700)
    for row in manifest['members']:
        path = source / row['path']
        assert sha(path) == row['sha256'] and path.stat().st_size == row['bytes']
        target = output / row['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(path.read_bytes())
    changes = []
    for path in sorted(output.rglob('*.py')):
        old = path.read_text()
        new = old.replace('gemma4-local-mtp-20260920-v2', 'gemma4-local-mtp-profile-20260920')
        if old != new:
            changes.append(dict(path=str(path.relative_to(output)), before=sha(path)))
            path.write_text(new)
            changes[-1]['after'] = sha(path)
    build_path = ROOT / 'build/local-mtp-profile-build-1.json'
    sources_path = ROOT / 'build/applied-local-mtp-profile.json'
    build = json.loads(build_path.read_bytes())
    assert build['exitCode'] == 0 and build['compilerReaped'] and build['groupAbsent']
    sources = json.loads(sources_path.read_bytes())
    assert sha(sources_path) == build['sourcesSHA256']
    path = output / 'required-native-sources.json'
    required = json.loads(path.read_bytes())
    required.update(actualBuildReceipt=dict(path=str(build_path), sha256=sha(build_path)),
                    actualSources=dict(path=str(sources_path), sha256=sha(sources_path)),
                    nativeSHA256=build['nativeSHA256'], nativeBytes=build['nativeBytes'],
                    requiredFiles=sources['files'])
    path.write_text(json.dumps(required, indent=2) + '\n')
    provenance = dict(schema='gemma4_phase_profile_harness_successor_v1',
                      baseSourceManifestSHA256=sha(source / 'source-inputs.json'),
                      changes=changes, arithmeticChanged=False,
                      sourceReceiptSHA256=sha(sources_path))
    (output / 'profile-provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    members = [dict(path=str(p.relative_to(output)), bytes=p.stat().st_size, sha256=sha(p))
               for p in sorted(output.rglob('*')) if p.is_file()]
    (output / 'source-inputs.json').write_text(json.dumps(dict(
        schema='gemma4_local_mtp_harness_sources_v1', members=members), indent=2) + '\n')
    print(json.dumps(dict(root=str(output), members=len(members),
                         sourceManifestSHA256=sha(output / 'source-inputs.json'))))


if __name__ == '__main__':
    main()
