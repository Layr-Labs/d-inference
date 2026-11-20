"""Apply exact reviewed source overlays in the isolated current-master tree."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
WORK = ROOT / 'workspace'


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def main():
    assert subprocess.check_output(['git', '-C', str(WORK), 'rev-parse', 'HEAD'], text=True).strip() == 'cc225365f866d9a0e6f565fe9426703785611f84'
    packages = [
        ('cluster-product-coordinator-composition-20260920', '33b56612cde8fac6d13058240797cf8228b18ca6f7a9eaaf4d02a0dab7cb16e4', 'initiation-overlay.json'),
        ('cluster-product-swift-initiation-composition-20260920', 'fb6efafc4bfd505eea4fbda393919a5e09b2c40aabdfaa41cfed85829f42c504', 'overlay.json'),
        ('cluster-product-app-attest-pair-20260920', '621e512c0904d710f5c6ee88774bbf7566be85361cdd65fa819b387df483b47e', 'overlay.json'),
    ]
    virtual = {}
    layers = []
    for name, wanted, overlay in packages:
        source = ROOT.parent / name
        manifest = (source / 'manifest.json').read_bytes()
        assert sha(manifest) == wanted, name
        index = json.loads(manifest)
        for row in index.get('members', index.get('files', [])):
            raw = (source / row['path']).read_bytes()
            assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], row['path']
        entries = json.loads((source / overlay).read_bytes())
        selected = []
        for row in entries:
            path = row['path']
            target = WORK / path
            assert not Path(path).is_absolute() and '..' not in Path(path).parts
            before = virtual[path] if path in virtual else target.read_bytes() if target.exists() else None
            assert (sha(before) if before is not None else None) == row['beforeSHA256'], path
            origin = Path(row['sourcePath']) if 'sourcePath' in row else source / 'proposed' / path
            after = origin.read_bytes()
            assert len(after) == row['bytes'] and sha(after) == row['sha256'], path
            virtual[path] = after
            selected.append((path, before, after))
        layers.append((name, wanted, selected))
    assert [len(rows) for _, _, rows in layers] == [10, 12, 27]
    preservation = ROOT / 'before-initiation-typed-identity'
    preservation.mkdir(mode=0o700)
    receipts = []
    for name, wanted, entries in layers:
        applied = []
        for path, before, after in entries:
            target = WORK / path
            assert (target.read_bytes() if target.exists() else None) == before
            if before is not None:
                backup = preservation / name / path
                backup.parent.mkdir(parents=True, exist_ok=True)
                with backup.open('xb') as stream:
                    stream.write(before)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(after)
            assert target.read_bytes() == after
            applied.append(dict(path=path, beforeSHA256=sha(before) if before is not None else None,
                                sha256=sha(after), bytes=len(after)))
        receipts.append(dict(package=name, manifestSHA256=wanted, files=applied))
    output = ROOT / 'initiation-typed-identity-overlay.json'
    with output.open('x') as stream:
        json.dump(dict(layers=receipts, finalFiles=[dict(path=p, bytes=len(b), sha256=sha(b))
                       for p, b in sorted(virtual.items())], mainModified=False, compiled=False), stream, indent=2)
    print(json.dumps(dict(status='applied', changes=49, finalFiles=len(virtual), receiptSHA256=sha(output.read_bytes()))))


if __name__ == '__main__':
    main()
