"""Replay the narrow source transformations; parse/import without subprocesses."""
import ast
import hashlib
import importlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
def sha(raw): return hashlib.sha256(raw).hexdigest()

def main():
    provenance = json.loads((ROOT / 'copy-provenance.json').read_bytes())
    for row in provenance['members']:
        before = Path(row['sourcePath']).read_bytes()
        assert sha(before) == row['beforeSHA256']
        after = before
        for operation in row['transforms']:
            a, b = operation['before'].encode(), operation['after'].encode()
            assert operation['kind'] == 'exact-bytes' and after.count(a) == operation['count']
            after = after.replace(a, b)
        actual = (ROOT / row['path']).read_bytes()
        assert actual == after and sha(actual) == row['afterSHA256'] and len(actual) == row['bytes']
    manifest = json.loads((ROOT / 'source-inputs.json').read_bytes())
    for row in manifest['members']:
        raw = (ROOT / row['path']).read_bytes()
        assert len(raw) == row['bytes'] and sha(raw) == row['sha256']
    paths = [ROOT / row['path'] for row in provenance['members'] if row['path'].endswith('.py')]
    paths += [ROOT / name for name in ['root_run.py', 'remote_metadata.py', 'check_source.py']]
    for path in paths: ast.parse(path.read_bytes(), filename=str(path))
    sys.path[:0] = [str(ROOT), str(ROOT / 'package')]
    def forbidden(*args, **kwargs): raise AssertionError('Import attempted a subprocess')
    old = subprocess.Popen
    subprocess.Popen = forbidden
    try:
        names = ['run_case', 'deploy', 'prepare_memory', 'parent_settings', 'alias',
            'lease_source', 'owned_process', 'compare_results', 'compare_results_v2',
            'compare_results_overlap', 'analyze_guard_metrics', 'analyze_guard_metrics_v1',
            'root_run', 'remote_metadata', 'native_gate', 'benchmark_package', 'target_processes',
            'jaccl_startup_stderr', 'worker_processes', 'gemma_inputs', 'reference_resources',
            'mtp_journal', 'worker_contract', 'binding_inputs', 'binding_common', 'run_benchmark',
            'stage_checks.common']
        for name in names: importlib.import_module(name)
        from remote_metadata import REMOTE_BODY
        ast.parse((ROOT / 'owned_process.py').read_text() + '\n' + REMOTE_BODY)
    finally:
        subprocess.Popen = old
    print(json.dumps(dict(schema='gemma4_decode_harness_source_check_v1', passed=True,
        exactSourceCopies=len(provenance['members']), baseMembers=len(manifest['members']),
        pythonAST=len(paths), importedModules=len(names), remoteHelperAST=True,
        childrenExecuted=False, nativeExecuted=False, remoteExecuted=False)))

if __name__ == '__main__': main()
