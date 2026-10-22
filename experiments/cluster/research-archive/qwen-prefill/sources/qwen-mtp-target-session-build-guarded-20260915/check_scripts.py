"""AST and exact-byte checks only; never imports or invokes a build script."""
from pathlib import Path
import ast
import hashlib
import json

BASE = Path(__file__).resolve().parent
OLD = BASE.parent / 'qwen-mtp-target-verification-build-20260915'
DRAFT = BASE.parent / 'qwen-mtp-target-session-draft-20260915'


def pin(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    scripts = sorted(BASE.glob('*.py'))
    for path in scripts:
        ast.parse(path.read_text(), filename=str(path))
    lineage = json.loads((BASE / 'lineage.json').read_bytes())
    assert pin(DRAFT / 'manifest.json') == lineage['draftManifestSHA256']
    assert pin(BASE / 'runtime.patch') == lineage['runtimePatchSHA256']
    rows = json.loads((BASE / 'integration.json').read_bytes())['files']
    assert rows == lineage['copiedOverlayFiles'] and len(rows) == 10
    for row in rows:
        assert pin(BASE / 'overlay' / row['path']) == row['sha256']
        assert pin(DRAFT / 'proposed' / row['path']) == row['sha256']
    build = (BASE / 'build_native.py').read_text()
    inverse = build.replace("PRODUCT='TargetVerificationSessionCheck'", "PRODUCT='TargetVerificationCheck'")
    inverse = inverse.replace("'-Xswiftc','-DQWEN_TARGET_TINY_FIXTURE',", '')
    inverse = inverse.replace('                if child.returncode is None:\n                    try:os.killpg(child.pid,signal.SIGKILL)\n                    except ProcessLookupError:pass\n', '                try:os.killpg(child.pid,signal.SIGKILL)\n                except ProcessLookupError:pass\n')
    assert inverse == (OLD / 'build_native.py').read_text()
    assert (BASE / 'verify_build_inputs.py').read_bytes() == (OLD / 'verify_build_inputs.py').read_bytes()
    cache = (BASE / 'prepare_cache.py').read_text()
    assert "SOURCE=OLD/'workspace/libs/darkbloom-cluster-worker/.build-native-worker'" in cache
    assert "OLD=BASE.parent/'qwen-mtp-target-verification-build-20260915'" in cache
    assert "cache.rename(held)" in cache and "('checkouts','repositories')" in cache
    commands = json.loads((BASE / 'commands.json').read_bytes())
    assert [row['name'] for row in commands['sequential']] == ['sources','cache','snapshot','native','package']
    assert commands['gpuRunAuthorizedByBuild'] is False
    assert 'run-tiny-session-on-gpu' not in build
    assert not (BASE / 'workspace').exists()
    result = dict(status='passed', pythonASTFiles=len(scripts), overlayFiles=len(rows),
                  buildRunnerInverseExact=True, verifierExact=True,
                  productPrivateDefineAndUnreapedChildSignalGuardChanged=True,
                  copiedOverlayBytes=sum((BASE/'overlay'/row['path']).stat().st_size for row in rows),
                  workspaceMaterialized=False, cacheCloned=False, compilerExecuted=False,
                  nativeFixtureExecuted=False, modelGPUOrRemoteExecuted=False,
                  inputPins=[dict(path=path.name,sha256=pin(path)) for path in scripts])
    with (BASE / 'source-script-checks.json').open('x') as stream:
        json.dump(result, stream, indent=2); stream.write('\n')
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
