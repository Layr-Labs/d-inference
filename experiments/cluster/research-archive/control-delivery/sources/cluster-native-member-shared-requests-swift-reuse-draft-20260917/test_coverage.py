"""Small parser controls only; synthesized additions are not execution evidence."""
import json
import re
import unittest
from context import BASE,PRIOR
from coverage import validate

class CompletionControls(unittest.TestCase):
    def setUp(self):
        self.raw=(PRIOR/'tests-2/execution.stdout').read_text()+'\n'+(PRIOR/'tests-2/execution.stderr').read_text()
        c=json.loads((BASE/'coverage.json').read_text())
        names=[x for x in sum(c['groups'].values(),[]) if x+'()' not in c['priorCompletionLabels']]
        self.extra='\n'.join('✔ Test '+x+'() passed after 0.001 seconds.' for x in names)
        self.complete=self.raw.replace('Test run with 88 tests in 14 suites','Test run with '+str(88+len(names))+' tests in 18 suites')+'\n'+self.extra+'\n'
    def test_exact_prior_and_new_membership(self):
        result=validate(self.complete)
        self.assertEqual(result['priorCompletionLabelsPreserved'],88)
        self.assertEqual(result['requiredMethodGroups'],dict(invocation=10,mesh=6,attachment=6,shared=6))
    def test_missing_or_duplicate_completion_refused(self):
        line=self.extra.splitlines()[0]
        for value in [self.complete.replace(line,'◇ Test discovery only.'),self.complete+'\n'+line]:
            with self.assertRaises(ValueError):validate(value)
    def test_prior_method_omission_refused(self):
        label=json.loads((BASE/'coverage.json').read_text())['priorCompletionLabels'][0]
        value=re.sub(r'(?m)^✔ Test '+re.escape(label)+r' passed after [^\n]+$','',self.complete)
        with self.assertRaises(ValueError):validate(value)
    def test_member_case_count_failure_and_summary_refused(self):
        for value in [self.complete.replace('with 2 test cases passed','with 1 test cases passed'),
                      self.complete+'\n✘ Test fixture failed.\n',self.complete.replace('Test run with 106 tests','Test run with 107 tests')]:
            with self.assertRaises(ValueError):validate(value)
if __name__=='__main__':unittest.main()
