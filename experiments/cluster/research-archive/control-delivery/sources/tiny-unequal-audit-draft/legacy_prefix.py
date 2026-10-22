"""Execute only three pinned pure audit functions; never import the old launcher."""
import ast
from pathlib import Path
from tiny12_expected import require, sha

SOURCE_SHA256 = '569a9532289c43680ca33d1dc8afcc45d03398bb8ca042f2aad3a74e57391518'
NAMES = ('check_fixture_records', 'check_lifecycle_records', 'check_records')


def functions():
    path = Path(__file__).parent / 'frozen' / 'validate-qwen-layer-stage.py'
    with path.open('rb') as handle:
        raw = handle.read(65537)
    require(len(raw) <= 65536 and sha(raw) == SOURCE_SHA256, 'Frozen legacy auditor source pin differs')
    tree = ast.parse(raw, filename=str(path))
    selected = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in NAMES]
    require(tuple(node.name for node in selected) == NAMES, 'Legacy pure-function inventory differs')
    namespace = {'require': require}
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), 'exec'), namespace)
    return namespace


def check_legacy_prefix(rows):
    require(type(rows) is list and len(rows) == 11, 'Legacy prefix must retain exactly eleven records')
    return functions()['check_records'](rows)
