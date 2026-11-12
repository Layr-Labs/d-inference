"""Prospective 8K scope checks over fabricated evidence and declared metadata."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
from prepare_inputs import BASE, ROOT, AUDIT, AUDIT_SHA, PROMPT_SOURCE, PROMPT_SHA, pin
sys.path.insert(0,str(AUDIT))
from audit_scope import AuditScope, pinned_scope
from audit_common import request_context, agreement
from audit_reference import check_reference
from audit_candidate import compare
from fabricated import fixture, reference_bytes


class EightKChecks(unittest.TestCase):
    def test_exact_prompt_catalog_and_declared_scope(self):
        self.assertEqual((BASE/'inputs/prompt.ids.json').read_bytes(),PROMPT_SOURCE.read_bytes())
        self.assertEqual(pin(BASE/'inputs/prompt.ids.json')['sha256'],PROMPT_SHA)
        self.assertEqual((BASE/'provenance/registered_profiles.json').read_bytes(),(AUDIT/'registered_profiles.json').read_bytes())
        request=json.loads((BASE/'inputs/request.json').read_bytes())
        metadata=json.loads((BASE/'provenance/recording-metadata.json').read_bytes())
        scope=pinned_scope(request,metadata)
        self.assertEqual((scope.prompt,scope.chunk,scope.output,scope.cut,scope.frames,scope.frontier),(8192,512,128,16,143,8319))
        context=request_context((BASE/'inputs/prompt.ids.json').read_bytes(),request['requestID'],scope)
        agreement(json.loads((BASE/'expected-agreement.json').read_bytes()),context)
        self.assertEqual(pin(AUDIT/'manifest.json')['sha256'],AUDIT_SHA)

    def test_complete_fabricated_8k_and_short_scope_refusal(self):
        request=json.loads((BASE/'inputs/request.json').read_bytes())['requestID']
        scope=AuditScope('registered_qwen38_27b',8192,512,128,16)
        _,context,admitted,report,expected,candidates=fixture(scope,request)
        raw=reference_bytes(admitted,report)
        result=compare(check_reference(raw,context),candidates,expected,context)
        self.assertEqual((result['comparedSelectedTokenCount'],result['finalCompletedFrames'],result['finalCommittedTokens']),(128,143,8319))
        self.assertEqual(result['stageStateEntryCounts'],[36,108])
        self.assertEqual(result['orderedStateEntriesCompared'],144)
        self.assertEqual(result['finalNativeBF16RowBytesCompared'],496640)
        _,_,short_admitted,short_report,_,_=fixture(AuditScope('registered_qwen38_27b',32,16,128,16),request)
        with self.assertRaises(ValueError):check_reference(reference_bytes(short_admitted,short_report),context)
        corrupted=copy.deepcopy(candidates);corrupted[1]['execution']['committedTokens']=159
        with self.assertRaises(ValueError):compare(check_reference(raw,context),corrupted,expected,context)

    def test_existing_reference_validator_accepts_job_geometry(self):
        package=ROOT/'qwen27b-cut16-full-reference-20260915/package'
        sys.path.insert(0,str(package))
        from reference_inputs import validate_job
        job=json.loads((BASE/'reference-job.json').read_bytes())
        self.assertEqual(validate_job(job),job)
        bad=dict(job,prompt_count=8193)
        with self.assertRaises(ValueError):validate_job(bad)


if __name__=='__main__':unittest.main()
