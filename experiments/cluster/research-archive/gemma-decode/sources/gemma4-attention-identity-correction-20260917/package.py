"""Create-only successor bundle after a passed actual corrected build."""
import json, re, shutil, sys
from common import BASE, OLD, BINARY, sha, verify

def main():
    if len(sys.argv) != 2 or not re.fullmatch(r'native-[1-9][0-9]*', sys.argv[1]):
        raise ValueError('One passed native-N attempt required')
    verify(True)
    receipt = json.loads((BASE / sys.argv[1] / 'receipt.json').read_bytes())
    if receipt['status'] != 'passed' or sha(BINARY) != receipt['binary']['sha256'] or any(
            row.get('exitCode') != 0 or not row.get('reaped') or not row.get('groupAbsent') for row in receipt['steps']):
        raise ValueError('Build/control terminal proof changed')
    out = BASE / (sys.argv[1] + '-bundle'); out.mkdir(mode=0o700)
    controls = json.loads((OLD / 'resource-controls.json').read_bytes())['files']
    rows = [dict(path=BINARY.name, bytes=BINARY.stat().st_size, sha256=sha(BINARY))] + controls
    for row in rows:
        source = BINARY.parent / row['path']; target = out / row['path']
        if source.is_symlink() or source.stat().st_size != row['bytes'] or sha(source) != row['sha256']:
            raise ValueError('Native bundle source changed')
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
        if sha(target) != row['sha256']: raise ValueError('Bundle copy changed')
    (out / 'bundle.json').write_text(json.dumps(dict(buildReceiptSHA256=sha(BASE / sys.argv[1] / 'receipt.json'),
        sourceSnapshotSHA256=sha(BASE / 'preparation/source-snapshot.json'), files=rows), indent=2, sort_keys=True) + '\n')
    print(sha(out / 'bundle.json'))

if __name__ == '__main__': main()
