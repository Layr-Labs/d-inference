"""Small source/metadata checks only; no cache traversal, compiler or model."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import shutil
from build_inputs import BASE, OLD, authority


def main():
    sources, dependencies, expected, changed = authority()
    for path in BASE.rglob('*.py'):
        if 'workspace' not in path.parts:
            ast.parse(path.read_text(), filename=str(path))
    for name in ('prepare.py', 'owned_process.py'):
        assert (BASE/name).read_bytes() == (OLD/name).read_bytes(), name
    before = (OLD/'build_check.py').read_text()
    after = (BASE/'build_check.py').read_text()
    assert after.replace('accepted=22, rejected=42', 'accepted=19, rejected=35') == before
    rel = 'experiments/cluster/inference/Sources/ClusterInference/'
    for name in ('QwenResidentSoloRequest.swift', 'QwenResidentSoloTiming.swift',
                 'QwenFullGenerationReferenceResources.swift', 'QwenResidentSoloModelScope.swift'):
        assert rel+name not in changed
        assert expected[rel+name] == sources[rel+name]
    with tempfile.TemporaryDirectory(prefix='solo-short-source-inverse-') as directory:
        directory = Path(directory)
        shutil.copytree(BASE/'proposed', directory/'tree')
        result = subprocess.run(['/usr/bin/patch', '-R', '-p1', '--batch', '-i', str(BASE/'runtime.patch')],
                                cwd=directory/'tree', capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr.decode()
        for name in changed:
            original = BASE/'originals'/name
            restored = directory/'tree'/name
            if original.exists():
                assert restored.read_bytes() == original.read_bytes(), name
            else:
                assert not restored.exists(), name
    print(json.dumps(dict(passed=True, baseSourceMembers=len(sources), dependencyMembers=len(dependencies),
        proposedSourceMembers=len(expected), changedRuntimeOrFixturePaths=changed,
        requestMathTimingAndResourcesUnchanged=True, inversePatchPassed=True,
        compilerExecuted=False, modelExecuted=False, fullWorkspaceHashPerformed=False)))


if __name__ == '__main__':
    main()
