"""Read-only small-source checks. Does not compile or touch model/cache payloads."""
import ast
import difflib
import hashlib
import json
from pathlib import Path

BASE = Path(__file__).resolve().parent


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    preimages = json.loads((BASE / 'preimages.json').read_bytes())['files']
    groups = {'runtime.patch': [], 'owner.patch': [], 'metadata.patch': [], 'reference-check.patch': []}
    changed = []
    for row in preimages:
        original = BASE / 'originals' / row['path']
        proposed = BASE / 'proposed' / row['path']
        require(original.read_bytes() == Path(row['source']).read_bytes(), 'Preimage source changed')
        require(original.stat().st_size == row['bytes'] and digest(original) == row['sha256'], 'Preimage pin changed')
        if original.read_bytes() != proposed.read_bytes():
            changed.append(row['path'])
        group = ('owner.patch' if row['path'].startswith('Owner/') else
                 'metadata.patch' if row['path'].startswith('Metadata/') else
                 'reference-check.patch' if row['path'].startswith('FullReference/') else 'runtime.patch')
        groups[group].append(''.join(difflib.unified_diff(original.read_text().splitlines(True),
            proposed.read_text().splitlines(True), fromfile='a/' + row['path'], tofile='b/' + row['path'])))
    for name, pieces in groups.items():
        require((BASE / name).read_text() == ''.join(pieces), 'Patch differs from full source: ' + name)
    native = 'libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentModelDefinition.swift'
    original = (BASE / 'originals' / native).read_text()
    proposed = (BASE / 'proposed' / native).read_text()
    start = proposed.index('            // Explicit native validation follows')
    end = proposed.index('            supportsLookahead = false', start)
    inverse = proposed[:start] + '            supportedCuts = Self.nineBCuts + [specification.layers / 2]\n' + proposed[end:]
    require(inverse == original, 'Native inverse is not the exact ancestor')
    require(len(changed) == 5 and changed.count(native) == 1, 'Unexpected source change set')
    require((BASE / 'proposed/Owner/OwnerNativeDiagnostics.swift').read_bytes() ==
            (BASE / 'originals/Owner/OwnerNativeDiagnostics.swift').read_bytes(), 'Diagnostics changed')
    reference = (BASE / 'proposed/FullReference/QwenFullGenerationReferenceCheck.swift').read_text()
    require(reference.replace('("--stage-cut", "21")', '("--stage-cut", "20")') ==
            (BASE / 'originals/FullReference/QwenFullGenerationReferenceCheck.swift').read_text(), 'Reference test inverse differs')
    require('for cut in definition.supportedCuts {' in reference, 'Positive structural cut coverage missing')
    inputs = json.loads((BASE / 'control-inputs.json').read_bytes())
    for row in inputs['files']:
        path = Path(row['path'])
        require(path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], 'Small control input changed: ' + str(path))
    require(inputs['runtimeOverlay'] == [native] and inputs['accountingRuntimeEnabled'] is False,
            'Prospective accounting entered the native overlay')
    plan = json.loads((BASE / 'native-qualification-plan.json').read_bytes())
    require(plan['accountingIncludedInNative'] is False and plan['guards']['actualFreeBytes'] == 6 * 1024**3,
            'Resource plan changed')
    for role, ancestor in plan['ancestors'].items():
        for key in ['sourceSnapshot', 'dependencySnapshot', 'bundleManifest', 'definitionPreimage']:
            row = ancestor[key]
            require(Path(row['path']).stat().st_size == row['bytes'] and digest(Path(row['path'])) == row['sha256'],
                    'Native ancestry descriptor changed: ' + role + '/' + key)
        require(ancestor['definitionPreimage']['sha256'] == preimages[0]['sha256'], 'Native product preimages differ')
        require(ancestor['definitionOverlay'] == 'proposed/' + native, 'Native products take different runtime overlays')
    for path in BASE.glob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
    manifest = BASE / 'manifest.json'
    member_count = None
    if manifest.exists():
        members = json.loads(manifest.read_bytes())['files']
        for row in members:
            path = BASE / row['path']
            require(path.stat().st_size == row['bytes'] and digest(path) == row['sha256'], 'Frozen member changed')
        member_count = len(members)
    print(json.dumps(dict(passed=True, changedSourceFiles=changed, runtimeOverlaysPerNativeProduct=1,
        controlSourcePins=len(inputs['files']), frozenMembers=member_count,
        dependencyArtifactHashesChecked=False, compilerOrNativeOrRemoteExecuted=False,
        behavioralTestsExecuted=False, accountingRuntimeEnabled=False), sort_keys=True))


if __name__ == '__main__':
    main()
