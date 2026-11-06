#!/usr/bin/env python3
"""Source-only extraction/preservation checks; no Swift or model execution."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
RUNTIME = Path('libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(base):
    original = (ROOT / 'originals/QwenResidentMTPLoading.swift').read_text()
    assert original == (base / RUNTIME / 'QwenResidentMTPLoading.swift').read_text()
    current = (ROOT / 'proposed' / RUNTIME / 'QwenResidentMTPLoading.swift').read_text()
    begin = original.index('                let loaded = try loadPreparedQwenResidentStage')
    end = original.index('\n            }\n        } catch', begin)
    old_body = original[begin:end]
    expected = '\n'.join(line[12:] if line.startswith('            ') else line
                         for line in old_body.splitlines()).replace('checked', 'check')
    helper_start = current.index('    let loaded = try loadPreparedQwenResidentStage', current.index('func materializePrepared'))
    assert current[helper_start:current.rindex('\n}')] == expected
    wrapper = current[:current.index('\n\n/// Same materialization body')]
    changed = original[:begin] + '                return try materializePreparedQwenResidentMTPAssets(admission, source: source, check: checked)' + original[end:]
    assert wrapper.rstrip() == changed.rstrip()
    preserved = []
    for name in ('WorkerConfiguration.swift', 'WorkerBootstrapConfiguration.swift'):
        src = base / 'libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker' / name
        dst = ROOT / 'proposed/libs/darkbloom-cluster-worker/Tests/MTPSelectedLoadCheck' / name
        assert src.read_bytes() == dst.read_bytes()
        preserved.append({'path': str(src.relative_to(base)), 'sha256': sha(src)})
    for path in (ROOT / 'proposed' / RUNTIME).glob('*.swift'):
        assert 'Collective(' not in path.read_text()
    target = base / RUNTIME / 'QwenResidentLoading.swift'
    assert not (ROOT / 'proposed' / RUNTIME / target.name).exists()
    return {'status': 'passed', 'scope': 'source-only; no compiler, model or native execution',
            'unchangedTargetLoadingSHA256': sha(target), 'copiedParserSources': preserved,
            'materializationBodyEquivalent': True,
            'allowedBodyChanges': ['indentation', 'checked callback renamed check'],
            'noCollectiveConstructorInOverlay': True}


if __name__ == '__main__':
    print(json.dumps(main(Path(sys.argv[1]).resolve()), indent=2))
