"""No-child replay of this source-only harness and its immutable parent."""
import hashlib
import json
from pathlib import Path
import check_source

ROOT = Path(__file__).resolve().parent
def sha(raw): return hashlib.sha256(raw).hexdigest()

def main():
    value = json.loads((ROOT / 'copy-provenance.json').read_bytes())
    assert sha(Path(value['parentManifestPath']).read_bytes()) == value['parentManifestSHA256']
    for row in json.loads((ROOT / 'manifest.json').read_bytes())['members']:
        raw = (ROOT / row['path']).read_bytes()
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256'], row['path']
    check_source.main()
    print(json.dumps(dict(schema='gemma4_cpu_control_harness_check_v1', passed=True,
        parentManifestVerified=True, compilerExecuted=False, nativeExecuted=False,
        remoteExecuted=False, childrenExecuted=False)))

if __name__ == '__main__': main()
