"""CPU-only source/delta verification, independent of any candidate output."""
import ast
import difflib
import json
from pathlib import Path
from tiny12_expected import canonical, expected, require, sha

HERE = Path(__file__).parent


def validate():
    old = (HERE / 'frozen/qwen_layer_stage_recorded_audit.py').read_bytes()
    legacy = (HERE / 'frozen/validate-qwen-layer-stage.py').read_bytes()
    new = (HERE / 'tiny12_recorded.py').read_bytes()
    require(sha(old) == 'ba943e3ec2157447d7725ab3ca030bb398813c82be6d4d4a1024d4fbf98d29e4', 'Recorded source pin')
    require(sha(legacy) == '569a9532289c43680ca33d1dc8afcc45d03398bb8ca042f2aad3a74e57391518', 'Legacy source pin')
    def functions(raw):
        return {node.name: ast.dump(node, include_attributes=False)
                for node in ast.parse(raw).body if isinstance(node, ast.FunctionDef)}
    before, after = functions(old), functions(new)
    require(set(before) == set(after), 'Recorded function inventory changed')
    changed = [name for name in before if before[name] != after[name]]
    require(changed == ['stage_inventory', 'check_recorded_pair'], 'Unexpected recorded algorithm delta')
    start, end = "    recorded = baseline['request']; spec = recorded['request']", '    baseline_hash = '
    original_block = old.decode().split(start, 1)[1].split(end, 1)[0]
    changed_block = new.decode().split(start, 1)[1].split(end, 1)[0]
    require(changed_block == original_block.replace('72 if expected else 18', '72 if expected else 27'),
            'Timeline/state/logit/fingerprint math changed beyond tiny state count')
    patch = ''.join(difflib.unified_diff(old.decode().splitlines(True), new.decode().splitlines(True),
        fromfile='frozen/qwen_layer_stage_recorded_audit.py', tofile='tiny12_recorded.py'))
    require((HERE / 'recorded-oracle-tiny12.diff').read_text() == patch, 'Mechanical patch differs')
    syntax = []
    for path in sorted(HERE.glob('*.py')):
        ast.parse(path.read_bytes(), filename=path.name)
        syntax.append(path.name)
    metadata = expected()
    return dict(kind='prospective_tiny12_audit_source_check', passed=True, changedRecordedFunctions=changed,
        unchangedRecordedFunctions=[name for name in before if name not in changed],
        unchangedLegacyFunctions=['check_fixture_records', 'check_lifecycle_records', 'check_records'],
        requestFrameStateLogitMathPreservedExceptExpectedCount=True,
        sourceDerivedMetadataSHA256=sha(canonical(metadata)), pythonSyntaxFiles=syntax,
        candidateAccessed=False, nativeOrSSHExecuted=False)


if __name__ == '__main__':
    print(json.dumps(validate(), sort_keys=True, indent=2))
