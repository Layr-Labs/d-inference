"""Check retained source equality and the selected descriptor's native metadata origin."""
import argparse
import ast
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONTROL_SHA = 'e6e062466026e921502e85159cdce293bbd6570cb4c6de6c6b4026c6bf006b89'


def sha(raw): return hashlib.sha256(raw).hexdigest()


def literal(node):
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'dict' and not node.args:
        return {item.arg: literal(item.value) for item in node.keywords if item.arg is not None}
    if isinstance(node, ast.Dict): return {literal(k): literal(v) for k, v in zip(node.keys, node.values)}
    return ast.literal_eval(node)


def run(repository, control_path):
    pinned = json.loads((HERE / 'source-pins.json').read_bytes())['repository_sources']
    for item in pinned:
        old = (HERE / 'originals' / item['path']).read_bytes(); current = (repository / item['path']).read_bytes()
        assert old == current and sha(old) == item['sha256'] and len(old) == item['size_bytes']
    raw = control_path.read_bytes(); assert sha(raw) == CONTROL_SHA
    control = json.loads(raw)
    assert control['cpuMetadataOnly'] is True and control['nativeModelExecution'] is False
    source = HERE / 'proposed/experiments/cluster/runtime/stage_checks/long_stage_cut.py'
    tree = ast.parse(source.read_text()); values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
            values[node.targets[0].id] = literal(node.value)
    selected = values['_SELECTIONS'][12]
    assert selected['policies'] == ('serial_v1',)
    assert selected['plan'] == control['planSHA256']
    assert selected['ranges'] == tuple((stage['sourceLayerStart'], stage['sourceLayerEnd']) for stage in control['stages'])
    assert selected['stages'] == tuple(stage['fingerprint'] for stage in control['stages'])
    assert selected['configurations'] == tuple(stage['constructionConfigurationSHA256'] for stage in control['stages'])
    assert values['_TEXT_GEOMETRY'] == dict(num_hidden_layers=control['layers'], full_attention_interval=control['interval'])
    public_profile = ast.parse((HERE / 'originals/experiments/cluster/runtime/stage_checks/long_profile.py').read_text())
    config = next(ast.literal_eval(node.value) for node in public_profile.body if isinstance(node, ast.Assign)
                  and any(isinstance(target, ast.Name) and target.id == 'CONFIGURATION' for target in node.targets))
    assert config == control['sourceConfigurationSHA256']
    return dict(kind='public_long_cut_source_check', passed=True, retained_repository_files_unchanged=len(pinned),
        selected_descriptor_matches_pinned_native_metadata=True, native_control_sha256=CONTROL_SHA,
        python_plan_serializer_added=False, native_model_execution=False, candidate_output_accessed=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, required=True); parser.add_argument('--control', type=Path, required=True)
    args = parser.parse_args(); print(json.dumps(run(args.repository, args.control), indent=2, sort_keys=True))
