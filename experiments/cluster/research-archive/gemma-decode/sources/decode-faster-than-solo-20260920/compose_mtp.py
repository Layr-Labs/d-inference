"""Compose reviewed target-state and assistant seams; retain all preimages."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent
RESEARCH = ROOT.parent
WORK = RESEARCH / 'gemma4-execution-20260920/build/workspace'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(path):
    return dict(path=str(path.relative_to(WORK)), bytes=path.stat().st_size, sha256=sha(path))


def frozen(root, expected):
    path = root / 'manifest.json'
    assert sha(path) == expected
    for row in json.loads(path.read_bytes())['members']:
        source = root / row['path']
        assert source.stat().st_size == row['bytes'] and sha(source) == row['sha256']


def main():
    base_path = ROOT / 'build/applied-cpu-control.json'
    assert sha(base_path) == 'caa436da7cf7339eed7ae49dc799d212f8ee36dcf7bfb9b19eac8e9f0510f33e'
    base = json.loads(base_path.read_bytes())
    for row in base['files']:
        assert record(WORK / row['path']) == row
    draft = RESEARCH / 'gemma4-owned-rectangular-target-draft-20260920'
    successor = RESEARCH / 'gemma4-owned-rectangular-target-check-context-20260920'
    frozen(draft, 'a613272fca14d51ff0a784fc938c44a05b2846899a09e959e4d224be1f85ea00')
    frozen(successor, '17717904987396442418e1d6da64a91ffa81ac59cd3754701593b8649071ac81')
    changes = []
    for row in json.loads((draft / 'integration.json').read_bytes())['overlays']:
        if row['path'].startswith('libs/darkbloom-cluster-worker/'):
            continue
        changes.append(dict(path=row['path'], source=str(draft / row['sourcePath']),
                            before=row['before']['sha256'] if row['before'] else None,
                            after=row['after']['sha256']))
    assert len(changes) == 12
    for row in json.loads((successor / 'integration.json').read_bytes())['overlays']:
        current = next(value for value in changes if value['path'] == row['path'])
        assert current['after'] == row['before']['sha256']
        current['source'] = str(successor / row['sourcePath']); current['after'] = row['after']['sha256']
    spi_path = ROOT / 'mtp-audit/source-inputs.json'
    assert sha(spi_path) == '6b67cdafdd22742c11d47b3f3e42800531e2c8e7353be2879a2dc940528663d8'
    spi = json.loads(spi_path.read_bytes())
    for row in spi['newFiles']:
        path = Path(row['path'])
        assert path.stat().st_size == row['bytes'] and sha(path) == row['sha256']
    for row in spi['overlays']:
        assert row['expectedDestination'] == 'absent'
        changes.append(dict(path=row['destination'], source=row['source'], before=None, after=sha(Path(row['source']))))
    session_path = ROOT / 'target-session/integration.json'
    for row in json.loads(session_path.read_bytes())['changes']:
        changes.append(dict(path=row['path'], source=row['source'], before=row['beforeSHA256'], after=row['afterSHA256']))
    ledger = ROOT / 'mtp-audit/Sources/AsyncMTPProposalLedger.swift'
    assert sha(ledger) == '7337c76421bd290a0eb50415367e875ede4c55b1ab65b8e68332aa424a853250'
    changes.append(dict(path='libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/AsyncMTPProposalLedger.swift',
                        source=str(ledger), before=None, after=sha(ledger)))
    assert len({row['path'] for row in changes}) == len(changes)
    before_root = ROOT / 'build/before-mtp'
    before_root.mkdir(mode=0o700)
    for row in changes:
        path = WORK / row['path']
        assert sha(Path(row['source'])) == row['after']
        if row['before'] is None:
            assert not path.exists(), row['path']
        else:
            assert sha(path) == row['before'], row['path']
            saved = before_root / row['path']; saved.parent.mkdir(parents=True, exist_ok=True)
            with saved.open('xb') as stream:
                stream.write(path.read_bytes())
    for row in changes:
        path = WORK / row['path']; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(Path(row['source']).read_bytes())
    names = {row['path'] for row in base['files']} | {row['path'] for row in changes}
    composition = dict(schema='gemma4_mtp_seams_composition_v1', baselineSHA256=sha(base_path),
        stateManifestSHA256=sha(draft / 'manifest.json'), stateEntryManifestSHA256=sha(successor / 'manifest.json'),
        conditioningManifestSHA256=sha(spi_path), sessionIntegrationSHA256=sha(session_path), changes=changes,
        files=[record(WORK / name) for name in sorted(names)])
    output = ROOT / 'build/applied-mtp.json'
    with output.open('x') as stream:
        json.dump(composition, stream, indent=2)
    print(json.dumps(dict(status='composed', sourcesSHA256=sha(output), files=len(names), overlays=len(changes))))


if __name__ == '__main__':
    main()
