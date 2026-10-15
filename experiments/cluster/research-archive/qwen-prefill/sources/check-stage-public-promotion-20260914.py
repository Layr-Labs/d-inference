"""Promotion check: existing pure/fake tests, no actual process/socket creation."""
import ast
import hashlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

REPO=Path('/Users/developer/DarkbloomDev/d-inference')
RESEARCH=REPO.parent/'cluster-research'
TESTS=REPO/'experiments/cluster'
sys.path.insert(0,str(TESTS))

EXCLUDED_MODULES={'test_runtime_processes','test_persistent_failures','test_check_logits'}
EXCLUDED_CLASSES={'test_runtime_execution_path.ExecutionPathLifecycleTests',
                  'test_runtime_ffn_output_precision.FFNOutputPrecisionLifecycleTests',
                  'test_persistent_protocol.PersistentReceiptTests'}
EXCLUDED_METHODS={
 'test_persistent_protocol.PersistentProtocolTests.test_duplicate_id_and_bad_local_request_preserve_reusable_epoch',
 'test_persistent_protocol.PersistentProtocolTests.test_persistent_supervisor_flag_rejects_non_boolean_before_start',
 'test_runtime_execution_path.ExecutionPathTests.test_unsupported_synthetic_families_fail_before_process_or_output_creation',
 'test_runtime_ffn_output_precision.FFNOutputPrecisionTests.test_sparse_and_gemma_profiles_are_rejected_before_staging_or_process_creation',
 'test_runtime_ffn_precision.FFNBranchPrecisionTests.test_policy_mismatch_fences_actual_fixture_cohort_before_requests',
 'test_runtime_ffn_precision.FFNBranchPrecisionTests.test_gemma_nonnative_fixture_policies_survive_persistent_reuse_and_shutdown',
 'test_runtime_local_correctness.LocalCorrectnessTests.test_cli_invalid_metadata_or_bounds_never_creates_output_or_starts_executable',
}


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def flatten(suite):
 for item in suite:
  if isinstance(item,unittest.TestSuite):yield from flatten(item)
  else:yield item


def main():
 suite=unittest.defaultTestLoader.discover(str(TESTS),pattern='test*.py')
 included=[];excluded=[]
 for test in flatten(suite):
  name=test.id();module=name.split('.')[0];klass=name.rsplit('.',1)[0]
  blocked=module in EXCLUDED_MODULES or klass in EXCLUDED_CLASSES or name in EXCLUDED_METHODS
  blocked=blocked or module=='test_run_transport' and not name.endswith('.test_native_deadline_cannot_exceed_supervisor')
  (excluded if blocked else included).append(test)
 log=io.StringIO()
 with patch('subprocess.Popen',side_effect=AssertionError('No process creation in source-only promotion check')), \
      patch('subprocess.run',side_effect=AssertionError('No process creation in source-only promotion check')), \
      patch('socket.socket',side_effect=AssertionError('No socket creation in source-only promotion check')):
  result=unittest.TextTestRunner(stream=log,verbosity=2).run(unittest.TestSuite(included))
 log_path=RESEARCH/'stage-public-promotion-cpu-20260914.log';log_path.write_text(log.getvalue())
 owned=list((TESTS/'runtime/stage_checks').glob('*.py'))+[TESTS/'runtime/stage_checks/README.md',TESTS/'run_stage_checks.py']+list(TESTS.glob('test_stage_checks*.py'))
 for path in owned:
  if path.suffix=='.py':ast.parse(path.read_text(),filename=str(path))
  for forbidden in ('/Users/','100.109.','password=','BEGIN PRIVATE KEY','BEGIN OPENSSH PRIVATE KEY'):
   assert forbidden not in path.read_text(),('private source content',path)
 preserved=[]
 for folder in ('stage-p2p-launcher-draft','stage-rank-launcher-draft','stage-public-launcher-draft','stage-lookahead-launcher-draft'):
  manifest=RESEARCH/folder/'draft-cpu-check-receipt.json';value=json.loads(manifest.read_text())
  for name,expected in value['source_sha256'].items():assert digest(manifest.parent/name)==expected,(folder,name)
  preserved.append(dict(path=str(manifest),sha256=digest(manifest)))
 record=dict(kind='stage_public_launcher_promotion_cpu_check',schema_version=1,passed=result.wasSuccessful(),
  tests_passed=result.testsRun-len(result.failures)-len(result.errors),tests_failed=len(result.failures)+len(result.errors),
  dedicated_stage_test_count=sum(test.id().startswith('test_stage_checks')for test in included),
  existing_pure_fake_test_count=sum(not test.id().startswith('test_stage_checks')for test in included),
  included_test_ids=[test.id()for test in included],excluded_process_test_ids=[test.id()for test in excluded],
  exclusions_reason='Source-inspected tests create CPU subprocesses/CLI children; excluded by task no-process requirement.',
  no_actual_process_or_socket_creation_enforced=True,native_execution=False,model_payload_reads=False,
  source_sha256={path.relative_to(REPO).as_posix():digest(path)for path in sorted(owned)},
  preserved_private_manifests=preserved,private_literal_scan_passed=True,ast_parse_passed=True,
  log_sha256=digest(log_path),checker_sha256=digest(Path(__file__)))
 receipt=RESEARCH/'stage-public-promotion-cpu-20260914.json';receipt.write_text(json.dumps(record,sort_keys=True,indent=2)+'\n')
 print(json.dumps(dict(passed=record['passed'],tests=record['tests_passed'],failed=record['tests_failed'],
  dedicated=record['dedicated_stage_test_count'],existing=record['existing_pure_fake_test_count'],
  excluded=len(excluded),receipt=str(receipt),sha256=digest(receipt)),sort_keys=True))
 if not result.wasSuccessful():print(log.getvalue());raise SystemExit(1)


if __name__=='__main__':main()
