"""Read-only source overlay and byte-copy checks; no launcher/process execution."""
import ast
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
from readiness_contract import source_contract

ROOT = Path(__file__).resolve().parent
RESEARCH = ROOT.parent
REPOSITORY = RESEARCH.parent / 'd-inference'
PROPOSAL = RESEARCH / 'resident-cohort-readiness-check-draft'
NATIVE_PROPOSAL_SHA = 'dd7bf3b2866e574fdd199e022ee6bb21720037654742215f89164d84fb9dae92'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check():
    manifest = PROPOSAL / 'manifest.json'
    assert sha(manifest) == NATIVE_PROPOSAL_SHA
    native_members = json.loads(manifest.read_bytes())['files']
    for entry in native_members:
        path = PROPOSAL / entry['path']
        assert path.stat().st_size == entry['size_bytes'] and sha(path) == entry['sha256']
    python_files = sorted(ROOT.glob('*.py'))
    for path in python_files:
        ast.parse(path.read_text(), filename=path.name, feature_version=(3, 9))
    copies = [(ROOT / 'prefill_compute_archive.py', ROOT / 'originals/prefill_compute_archive.py'),
              (ROOT / 'prefill_compute_archive.py', RESEARCH / 'remote-solo-prefill-launcher-draft/prefill_compute_archive.py')]
    for name in ['processes.py', 'rank_worker.py', 'configuration.py']:
        copies.append((ROOT / 'originals' / name, REPOSITORY / 'experiments/cluster/runtime' / name))
    for first, second in copies:
        assert first.read_bytes() == second.read_bytes()
    sources = REPOSITORY / 'experiments/cluster/inference/Sources/ClusterInference'
    names = ['Collective.swift', 'Options.swift', 'Main.swift',
        'QwenLongPrefillResidentCohortReadiness.swift', 'QwenLongPrefillCohortReadinessAdmission.swift',
        'QwenLongPrefillCohortReadinessCheck.swift', 'QwenLongPrefillResidentCohortAgreement.swift',
        'QwenLongPrefillResidentRankFixture.swift', 'QwenLayerStageProfiledPrefillRequestSpec.swift',
        'QwenLayerStageProfiledPrefillRecordedRequest.swift']
    inputs = []
    with tempfile.TemporaryDirectory(prefix='readiness-source-overlay-') as temporary:
        output = Path(temporary)
        target = output / 'source/experiments/cluster/inference/Sources/ClusterInference'
        target.mkdir(parents=True)
        for name in names:
            proposed = PROPOSAL / 'proposed' / name
            source = proposed if proposed.exists() else sources / name
            shutil.copyfile(source, target / name)
            inputs.append(dict(path=str(source), intended_repository_path=str((sources/name).relative_to(REPOSITORY)),
                               sha256=sha(source)))
        contract = source_contract(output)
        rejected = []
        for name, before, after in [
            ('Collective.swift', 'Using loopback-test transport for correctness only;', 'Changed diagnostic;'),
            ('Options.swift', 'message + "\\n"', 'message + ""'),
            ('Main.swift', 'cluster-inference: \\(error)', 'other: \\(error)')]:
            path=target/name; original=path.read_text();assert before in original
            path.write_text(original.replace(before, after))
            try:
                try: source_contract(output)
                except ValueError: rejected.append(name)
                else: raise AssertionError('Changed source contract accepted: '+name)
            finally: path.write_text(original)
    return dict(kind='model_free_readiness_launcher_source_checks', passed=True,
        native_proposal_manifest_sha256=NATIVE_PROPOSAL_SHA,
        native_proposal_members_verified=len(native_members),
        python39_syntax_files=len(python_files), exact_copy_comparisons=len(copies),
        warning_source_overlay_passed=True, changed_diagnostics_rejected=rejected,
        source_inputs=inputs, source_contract=contract,
        launcher_or_native_or_ssh_executed=False, model_payload_or_candidate_read=False)


if __name__ == '__main__':
    print(json.dumps(check(), sort_keys=True, indent=2))
