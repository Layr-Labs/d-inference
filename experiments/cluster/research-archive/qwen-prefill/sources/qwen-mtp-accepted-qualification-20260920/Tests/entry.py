"""Model-free fabricated-value and source-rendering controls only."""
import json
from pathlib import Path
import sys
import unittest
BASE=Path(__file__).resolve().parent.parent
sys.path[:0]=[str(BASE/'Compare'),str(BASE/'Physical')]
from test_accepted_evidence import AcceptedEvidenceTests
from test_physical_templates import PhysicalTemplateTests
suite=unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(value)
                         for value in [AcceptedEvidenceTests,PhysicalTemplateTests]])
result=unittest.TextTestRunner(verbosity=2).run(suite)
passed=result.wasSuccessful() and result.testsRun==16
print(json.dumps(dict(status='passed' if passed else 'failed',tests=result.testsRun,
                     failures=len(result.failures),errors=len(result.errors),nativeExecuted=False,remoteExecuted=False)))
raise SystemExit(0 if passed else 1)
