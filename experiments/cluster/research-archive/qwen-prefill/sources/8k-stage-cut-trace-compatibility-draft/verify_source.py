"""Recheck only pinned source bytes; no imports of native code or model data."""
import argparse
import hashlib
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
LIVE=Path('/Users/developer/DarkbloomDev/d-inference/experiments/cluster/inference/Sources/ClusterInference')


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(source_root=None):
    data=json.loads((HERE/'source-compatibility.json').read_bytes())
    records=data['existingCriticalSources']+data['selectedCutSourceOverlay']
    assert len(data['existingCriticalSources'])==19 and len(data['selectedCutSourceOverlay'])==8
    for item in records:
        frozen=Path(item['frozenSourcePath']);current=Path(item['currentSourcePath'])
        selected=Path(source_root)/current.relative_to(LIVE) if source_root is not None else current
        assert frozen.stat().st_size==selected.stat().st_size==item['sizeBytes']
        assert digest(frozen)==digest(selected)==item['sha256'],selected
    root=HERE.parent
    for name,item in data['sourceManifestPins'].items():
        assert (root/name).stat().st_size==item['sizeBytes'] and digest(root/name)==item['sha256']
    return dict(status='passed',byteIdenticalExistingSources=19,selectedCutOverlaySources=8,
        checkedSourceRoot=str(source_root or LIVE),nativeExecution=False,newRankCandidateAccess=False,
        scope='Selected source bytes only; does not establish executable, invocation or complete archive provenance.')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root',type=Path,help='Optional saved archive directory corresponding to Sources/ClusterInference')
    print(json.dumps(verify(p.parse_args().source_root),indent=2,sort_keys=True))
