"""Apply separately qualified framing on top of the timestamp-only candidate."""
from pathlib import Path
import json
from build_timestamp import ROOT, WORK, digest, record

def main():
    draft = ROOT / 'control-frame-draft'
    assert digest(draft / 'manifest.json') == 'b657df56d6af805794245bcb3eaacb7d2f28afd6404dc0a62bb2dab61de9bf90'
    controls = json.loads((draft / 'foundation-1/receipt.json').read_bytes())
    assert controls['status'] == 'passed' and controls['sourceInputsUnchanged']
    assert len(controls['checks']) == 18
    prior_path = ROOT / 'build/applied-timestamp-2.json'
    assert digest(prior_path) == '825387810369acc31f46851f9b32bf5521c4beff3067f81e9d3f0ffa0fe9c172'
    prior = json.loads(prior_path.read_bytes())
    for row in prior['files']:
        assert record(WORK / row['path'], WORK) == row
    overlay = json.loads((draft / 'integration.json').read_bytes())
    assert len(overlay['files']) == 3
    for row in overlay['files']:
        target = WORK / row['path']
        assert (digest(target) if target.exists() else None) == row['beforeSHA256']
        incoming = Path(row['sourcePath'])
        assert incoming.stat().st_size == row['bytes'] and digest(incoming) == row['afterSHA256']
    preserve = ROOT / 'build/before-control-frame'
    preserve.mkdir(mode=0o700)
    for row in overlay['files']:
        target = WORK / row['path']
        if target.exists():
            backup = preserve / row['path']
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_bytes(target.read_bytes())
        target.write_bytes(Path(row['sourcePath']).read_bytes())
        assert digest(target) == row['afterSHA256']
    paths = {r['path'] for r in prior['files']} | {r['path'] for r in overlay['files']}
    source = dict(priorSourcesSHA256=digest(prior_path),
        integrationSHA256=digest(draft / 'integration.json'),
        controlsSHA256=digest(draft / 'foundation-1/receipt.json'),
        changes=['one padded control transfer replaces prefix plus body',
                 'additive native and host control-frame allowance'],
        files=[record(WORK / p, WORK) for p in sorted(paths)])
    out = ROOT / 'build/applied-control-frame.json'
    with out.open('x') as stream:
        json.dump(source, stream, indent=2)
    print(json.dumps(dict(sourcesSHA256=digest(out), files=len(source['files']))))

if __name__ == '__main__':
    main()
