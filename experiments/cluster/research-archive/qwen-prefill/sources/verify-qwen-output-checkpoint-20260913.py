"""CPU-only final evidence/source check. Does not launch model execution."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import re
import subprocess

ROOT = Path('/Users/developer/DarkbloomDev/d-inference')
RESEARCH = ROOT.parent / 'cluster-research'
MATRIX = RESEARCH / 'runs/qwen-ffn-output-precision-20260913'


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def command(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def read_json(path):
    return json.loads(Path(path).read_text())


matrix = read_json(MATRIX / 'receipt.json')
tested = read_json(MATRIX / 'source-manifest.json')
assert digest(MATRIX / 'source-manifest.json') == matrix['source_manifest_sha256']
changes = [item['path'] for item in tested
           if digest(ROOT / item['path']) != item['sha256']]
assert all(Path(name).suffix == '.md' for name in changes), changes

paths = command('git', 'ls-files', '--cached', '--others', '--exclude-standard',
                'experiments/cluster', 'docs/design/README.md',
                'docs/design/distributed-inference-goal.md',
                'docs/developer/build.md', 'docs/developer/test.md').splitlines()
paths = sorted(set(paths))
extra_code = set(paths) - {item['path'] for item in tested}
# Driver snapshots omit dotfiles; these two non-executable ignore lists are
# included in this final inventory, alongside docs outside the driver scope.
assert all(Path(name).suffix == '.md' or name in {
    'experiments/cluster/inference/.gitignore',
    'experiments/cluster/transport/.gitignore',
} for name in extra_code), extra_code
snapshot = [{'path': name, 'sha256': digest(ROOT / name)} for name in paths]
snapshot_path = RESEARCH / 'qwen-output-precision-final-source-manifest-20260913.json'
snapshot_path.write_text(json.dumps(snapshot, indent=2) + '\n')

cpu = read_json(RESEARCH / 'runtime-ffn-output-precision-python-20260913.json')
assert cpu['tests'] == 173 and cpu['result'] == 'OK' and cpu['exit_code'] == 0
assert all(digest(ROOT / name) == sha for name, sha in cpu['files'].items())
assert digest(cpu['log']) == cpu['log_sha256']
native_dir = ROOT / 'experiments/cluster/inference/.build/arm64-apple-macosx/release'
assert all(digest(native_dir / name) == sha
           for name, sha in matrix['bundle_files'].items())
protocol_path = RESEARCH / 'qwen-ffn-output-protocol-20260913.json'
protocol = read_json(protocol_path)
assert (protocol['version'], protocol['acceptedFixtures'], protocol['rejectedFixtures']) == (5, 4112, 97)
assert protocol['canonicalFixtureSHA256'] == cpu['canonical_worker_request_sha256']
operators = [json.loads(line) for line in
             (RESEARCH / 'qwen-ffn-output-operators-20260913.jsonl').read_text().splitlines()]
assert len(operators) == 75
ffn_checks = [item for item in operators if item['kind'] == 'ffn_output_precision_boundary']
assert len(ffn_checks) == 2
assert all(item['exactProjectionComparisons'] == 12 and
           item['storedParameterHandlesBytesAndLayoutPreserved'] and
           item['duplicateAttachmentRejectedWithoutMutation'] and
           item['moeAttachmentRejectedWithoutMutation'] for item in ffn_checks)

submodules = []
for path in ['libs/mlx', 'libs/mlx-swift', 'libs/mlx-swift-lm']:
    head = command('git', 'rev-parse', 'HEAD', cwd=ROOT / path)
    expected = command('git', 'ls-tree', 'HEAD', path).split()[2]
    clean = not command('git', 'status', '--porcelain', '--untracked-files=all', cwd=ROOT / path)
    assert head == expected and clean
    submodules.append({'path': path, 'head': head, 'tracked_and_untracked_clean': clean})

dependency_paths = [
    'experiments/cluster/inference/.generated-dependencies/overlay.json',
    'experiments/cluster/inference/.generated-dependencies/mlx-swift/Package.swift',
    'libs/mlx-swift/Package.swift',
    'experiments/cluster/inference/Package.resolved',
]
dependency_hashes = {name: digest(ROOT / name) for name in dependency_paths}
previous = read_json(RESEARCH / 'cbv2-final-verification-20260913.json')
assert dependency_hashes == previous['dependency_manifest_hashes']
overlay = read_json(ROOT / dependency_paths[0])
assert overlay['source_manifest_sha256'] == dependency_hashes[dependency_paths[2]]
assert overlay['generated_manifest_sha256'] == dependency_hashes[dependency_paths[1]]

credentials = (ROOT.parent / 'machines/CREDENTIALS.private.md').read_text()
private_values = [value for line in credentials.splitlines() if 'password' in line.lower()
                  for value in re.findall(r'`([^`]+)`', line) if len(value) >= 8]
assert private_values
private_patterns = [r'/Users/gaj', r'100\.109\.199\.72', r'100\.96\.148\.101',
                    r'BEGIN (?:OPENSSH|RSA|EC) PRIVATE KEY', r'id_ed25519_darkbloom_dev']
exceptions = []
for name in paths:
    content = (ROOT / name).read_text()
    assert '\x00' not in content, name
    for number, line in enumerate(content.splitlines(), 1):
        assert not line.rstrip() != line, (name, number, 'trailing whitespace')
        assert not any(re.search(pattern, line) for pattern in private_patterns), (name, number, 'private identifier')
        if any(value in line for value in private_values):
            assert name == 'docs/developer/build.md' and line.startswith('FROM '), (name, number, 'private value')
            original = command('git', 'show', 'HEAD:' + name).splitlines()
            assert line in original
            exceptions.append({'path': name, 'reason': 'Unchanged public base-image namespace; not a credential declaration'})

page = ROOT / 'experiments/cluster/inference/QWEN_OUTPUT_PRECISION.md'
for target in re.findall(r'\[[^\]]+\]\(([^)]+)\)', page.read_text()):
    if not re.match(r'https?://', target):
        assert (page.parent / target.split('#')[0]).resolve().exists(), target

subprocess.run(['git', 'diff', '--check'], cwd=ROOT, check=True)
docs_log = RESEARCH / 'qwen-output-precision-docs-check-20260913.log'
assert docs_log.read_text().strip() == 'docs-check: 280 file(s) OK'
native_processes = [line for line in command('ps', '-axo', 'pid=,comm=').splitlines()
                    if Path(line.strip().split(maxsplit=1)[-1]).name in
                    {'cluster-inference', 'cluster-transport'}]
assert not native_processes, native_processes

evidence = [
    'runs/qwen-ffn-output-smoke-20260913/receipt.json',
    'runs/qwen-ffn-output-precision-20260913/receipt.json',
    'runs/qwen-ffn-output-precision-20260913/independent-cpu-audit.json',
    'runs/qwen-output-boundaries-20260913/receipt.json',
    'runs/qwen-output-boundaries-20260913/independent-cpu-audit.json',
    'runs/qwen9-output-boundaries-20260913/receipt.json',
    'qwen9-output-boundaries-independent-audit-20260913.json',
    'runs/qwen-ffn-output-workers-20260913/receipt.json',
    'runs/qwen-ffn-output-workers-20260913/independent-worker-failure-cpu-audit.json',
    'runs/qwen-ffn-output-failures-20260913/receipt.json',
    'runs/qwen-ffn-output-failures-20260913/report-schema-erratum.json',
    'qwen-ffn-output-cli-rejections-20260913.json',
    'runtime-ffn-output-precision-python-20260913.json',
    'qwen38-output-gate-and-eligibility-audit-20260913.json',
]
for pattern in ['*ffn-output*independent*audit*.json', '*ffn-output*erratum*.json']:
    for file in RESEARCH.glob(pattern):
        evidence.append(str(file.relative_to(RESEARCH)))
    for file in (RESEARCH / 'runs').glob('qwen-ffn-output-*/' + pattern):
        evidence.append(str(file.relative_to(RESEARCH)))
result = {
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'goal_status': 'active',
    'git_head': command('git', 'rev-parse', 'HEAD'),
    'branch': command('git', 'branch', '--show-current'),
    'binary_sha256': matrix['binary_sha256'],
    'bundle_files': matrix['bundle_files'],
    'tested_source_manifest_sha256': matrix['source_manifest_sha256'],
    'current_source_manifest_sha256': digest(snapshot_path),
    'only_changes_since_native_matrix': changes,
    'additional_public_files': sorted(extra_code),
    'cpu_suite_sources_unchanged': True,
    'cpu_tests': cpu['tests'],
    'worker_protocol_check': protocol,
    'worker_protocol_receipt_sha256': digest(protocol_path),
    'operator_records': len(operators),
    'ffn_output_operator_checks': ffn_checks,
    'submodules': submodules,
    'dependency_manifest_hashes': dependency_hashes,
    'toolchain': command('xcodebuild', '-version') + '\n' + command('swift', '--version'),
    'sdk': command('xcrun', '--show-sdk-version'),
    'build_log_sha256': digest(RESEARCH / 'qwen-ffn-output-build-20260913.log'),
    'git_diff_check': True,
    'docs_check': docs_log.read_text().strip(),
    'docs_check_sha256': digest(docs_log),
    'public_files_scanned': len(paths),
    'private_identifier_and_whitespace_scan_passed': True,
    'existing_public_reference_exceptions': exceptions,
    'native_test_processes_remaining': len(native_processes),
    'evidence_sha256': {name: digest(RESEARCH / name) for name in sorted(set(evidence))},
    'physical_peer_check': '48GB peer SSH connect timed out; power/freeze/network cause unknown; no interface changes',
    'limitations': [
        'BF16 both-wide TP exact in 11/12 synthetic comparisons; remaining full-TP first-row failure unresolved',
        'Wider policies alter native solo outputs; same-policy TP agreement is not native-policy equivalence',
        'Real 9B evidence is six bounded solo diagnostics, not distributed or throughput qualification',
        'No physical RDMA or M3 Ultra qualification',
        'Failure receipt report_schema_version annotation is stale8; protocol5/binary schema9 are independently verified',
    ],
}
output = RESEARCH / 'qwen-output-precision-final-verification-20260913.json'
output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'status': 'passed', 'public_files': len(paths), 'cpu_tests': cpu['tests'],
                  'native_processes_remaining': len(native_processes), 'receipt': str(output)}, indent=2))
