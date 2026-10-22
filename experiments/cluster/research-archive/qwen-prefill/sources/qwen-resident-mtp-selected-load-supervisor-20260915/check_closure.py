"""Model-free package check; reads only this supervisor's Python/JSON files."""
import ast
import hashlib
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True

RUNTIME = set('run_mtp_load mtp_clock mtp_contract mtp_controls mtp_inputs mtp_journal '
              'mtp_observations binding_common binding_inputs reference_resources physical_common '
              'selected_read_accounting worker_contract worker_processes stage_checks.common '
              'stage_checks.long_profile'.split())
STDLIB = set('argparse copy dataclasses datetime decimal fcntl hashlib json math os pathlib pwd '
              're selectors signal stat subprocess sys threading time uuid'.split())
RESOURCES = ['inputs/'+name+'.json' for name in
             ('target-control', 'additional-tensors', 'arithmetic', 'devices')]


def check(root):
    files = {'stage_checks/__init__.py'} | set(RESOURCES)
    edges = {}
    for name in sorted(RUNTIME):
        relative = name.replace('.', '/')+'.py'
        source = root/relative
        tree = ast.parse(source.read_text(), filename=relative, feature_version=(3, 9))
        imports = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.update(item.name for item in node.names)
            elif isinstance(node, ast.ImportFrom):
                assert node.level == 0, 'Unexpected relative import'
                imports.add(node.module)
        assert all(item in RUNTIME or item in STDLIB for item in imports), (name, imports)
        edges[name] = sorted(imports & RUNTIME)
        files.add(relative)
    reached, pending = set(), ['run_mtp_load']
    while pending:
        name = pending.pop()
        if name not in reached:
            reached.add(name)
            pending.extend(edges[name])
    assert reached == RUNTIME, ('Unaccounted runtime modules', reached ^ RUNTIME)
    from mtp_controls import read_controls
    from mtp_inputs import Pins
    controls = read_controls(root, Pins())
    members = []
    for relative in sorted(files):
        raw = (root/relative).read_bytes()
        members.append(dict(path=relative, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
    manifest = root/'manifest.json'
    if manifest.exists():
        pinned = {v['path']:v for v in json.loads(manifest.read_text())['files']}
        assert all(pinned[v['path']] == v for v in members), 'Manifest omits or differs from runtime closure'
    return dict(schema='private_mtp_supervisor_closure_v1', modules=edges, files=members,
        targetTensorCount=len(controls['target']['activeTensors']), additionalTensorCount=len(controls['additional']),
        externalSystemCommands=['/usr/bin/python3', '/usr/sbin/sysctl', '/usr/bin/vm_stat', '/usr/bin/pmset'],
        externalInstalledBundle='job.deployment: separately pinned three-member native bundle plus bundle.json',
        externalModelMetadata=['job.model_dir/config.json', 'job.model_dir/manifest.json'],
        modelPayloadReadByThisCheck=False, nativeExecuted=False, networkUsed=False)


if __name__ == '__main__':
    print(json.dumps(check(Path(__file__).resolve().parent), sort_keys=True, separators=(',', ':')))
