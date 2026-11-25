"""Source-only lineage/import check. Does not import or execute draft helpers."""
import ast
from hashlib import sha256
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
REPO = BASE.parent / 'd-inference'
ORIGIN = BASE / 'long-prefill-rank-audit-draft/rank_trace.py'
sources = {
    'actions_origin': ORIGIN,
    'private_phase_contract': BASE / 'phase-clock-audit-draft/phase_contract.py',
    'private_phase_base': BASE / 'phase-clock-audit-draft/phase_base.py',
    'private_phase_audit': BASE / 'phase-clock-audit-draft/phase_clock_audit.py',
    'public_common': REPO / 'experiments/cluster/runtime/stage_checks/common.py',
    'public_profile': REPO / 'experiments/cluster/runtime/stage_checks/long_profile.py',
    'public_outer_validator': REPO / 'experiments/cluster/runtime/stage_checks/long_rank_contract.py',
    'public_request_identity': REPO / 'experiments/cluster/runtime/stage_checks/long_identity.py',
    'public_selected_cut': REPO / 'experiments/cluster/runtime/stage_checks/long_stage_cut.py',
}
raw = {name: path.read_bytes() for name, path in sources.items()}
trees = {}
draft_names = ['qwen_phase_actions.py', 'qwen_rank_phase.py', 'phase_fixture.py']
for name in draft_names:
    text = (HERE / name).read_text()
    trees[name] = ast.parse(text, feature_version=(3, 9))
    for forbidden in ('cluster-research', '/Users/', 'darkbloom-24', 'importlib', 'subprocess', 'ROOT', 'PINNED'):
        if forbidden in text:
            raise ValueError('Private or side-effecting dependency in ' + name)
origin = ast.parse(raw['actions_origin'])
for name in ['expected_actions', 'timing_flags']:
    old = next(n for n in origin.body if isinstance(n, ast.FunctionDef) and n.name == name)
    new = next(n for n in trees['qwen_phase_actions.py'].body if isinstance(n, ast.FunctionDef) and n.name == name)
    if ast.dump(old, include_attributes=False) != ast.dump(new, include_attributes=False):
        raise ValueError('Action/timing source extraction differs: ' + name)
public_functions = {n.name for n in ast.parse(raw['public_common']).body if isinstance(n, ast.FunctionDef)}
if not {'exact', 'integer', 'require', 'sha'} <= public_functions:
    raise ValueError('Public primitive API differs')
imports = [n.module for n in trees['qwen_rank_phase.py'].body if isinstance(n, ast.ImportFrom)]
if imports != ['runtime.stage_checks.common', 'runtime.stage_checks.long_profile', 'qwen_phase_actions']:
    raise ValueError('Pure dependency list differs')
if any(path.read_bytes() != raw[name] for name, path in sources.items()):
    raise ValueError('Source input changed during check')
result = dict(kind='qwen_rank_phase_source_lineage_check', passed=True,
    exactExtractedFunctions=['expected_actions', 'timing_flags'], python39ASTFiles=draft_names,
    helperOrFixtureExecuted=False, nativeCompilerSSHModelExecutionPerformed=False,
    sourcePins={name: dict(path=str(sources[name]), sha256=sha256(data).hexdigest(), byteCount=len(data))
                for name, data in raw.items()},
    draftPins={name: dict(sha256=sha256((HERE/name).read_bytes()).hexdigest(), byteCount=(HERE/name).stat().st_size)
               for name in draft_names})
print(json.dumps(result, indent=2, sort_keys=True))
