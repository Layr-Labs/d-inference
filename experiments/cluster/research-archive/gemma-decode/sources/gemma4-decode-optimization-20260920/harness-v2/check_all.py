"""Validate the frozen v1-to-v2 source-only replay and import closure."""
import ast
import hashlib
import json
from pathlib import Path

import check_source

ROOT = Path(__file__).resolve().parent
def sha(raw): return hashlib.sha256(raw).hexdigest()

def main():
    provenance = json.loads((ROOT / 'helper-provenance.json').read_bytes())
    parent = ROOT.parent / 'harness/manifest.json'
    assert sha(parent.read_bytes()) == provenance['parentManifestSHA256']
    for row in provenance['members']:
        raw = Path(row['sourcePath']).read_bytes()
        assert sha(raw) == row['beforeSHA256']
        for operation in row['transforms']:
            before, after = operation['before'].encode(), operation['after'].encode()
            assert operation['kind'] == 'exact-bytes' and raw.count(before) == operation['count']
            raw = raw.replace(before, after)
        assert raw == (ROOT / row['path']).read_bytes()
        assert len(raw) == row['bytes'] and sha(raw) == row['afterSHA256']
    helpers = json.loads((ROOT / 'helper-inputs.json').read_bytes())
    assert helpers['baseSourceManifestSHA256'] == sha((ROOT / 'source-inputs.json').read_bytes())
    for row in helpers['members']:
        raw = (ROOT / row['path']).read_bytes()
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256']
    ast.parse(Path(__file__).read_bytes(), filename=__file__)
    check_source.main()
    print(json.dumps(dict(schema='gemma4_decode_harness_v2_helper_check_v1', passed=True,
        exactHelperCopies=len(provenance['members']), compilerExecuted=False,
        nativeExecuted=False, remoteExecuted=False, childrenExecuted=False)))

if __name__ == '__main__': main()
