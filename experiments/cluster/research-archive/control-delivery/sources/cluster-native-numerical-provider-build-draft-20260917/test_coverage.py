"""Parser regression controls use explicit fabricated text, never product evidence."""
import hashlib,json,re,unittest
from pathlib import Path
from context import BASE,PRIOR
from coverage import validate

def original():
    path=PRIOR/'tests-1/execution.stdout'
    expected=next(x for x in json.loads((BASE/'context-pins.json').read_text()) if x['path']==str(path))
    raw=path.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=expected['sha256']:raise ValueError('Retained failed log changed')
    return raw.decode()

def fabricated_success():
    text=original()
    text=re.sub(r'(?m)^✘ Test .+ recorded an issue .+\n','',text)
    text=re.sub(r'(?m)^✘ Test (.+?) failed after ([0-9.]+) seconds with 1 issue\.$',r'✔ Test \1 passed after \2 seconds.',text)
    text=re.sub(r'(?m)^✘ Suite (.+?) failed after ([0-9.]+) seconds with 1 issue\.$',r'✔ Suite \1 passed after \2 seconds.',text)
    new=json.loads((BASE/'coverage.json').read_text())['newMethods']
    completions='\n'.join('✔ Test '+x+'() passed after 0.001 seconds.' for x in new)
    return text.replace('✘ Test run with 112 tests in 18 suites failed after 10.039 seconds with 1 issue.',
        completions+'\n✔ Test run with 117 tests in 19 suites passed after 10.039 seconds.')

class CoverageTests(unittest.TestCase):
    def test_retained_failure_never_qualifies(self):
        with self.assertRaises(ValueError):validate(original())
    def test_exact_117_members_and_both_websocket_cases_required(self):
        self.assertEqual(validate(fabricated_success())['actualDiscoveredMethodsPassed'],117)
    def test_each_inherited_and_new_completion_is_required(self):
        proof=json.loads((BASE/'coverage.json').read_text())
        for label in proof['completionLabels']:
            changed=re.sub(r'(?m)^✔ Test '+re.escape(label)+r' passed after [^\n]+\n','',fabricated_success())
            with self.subTest(label=label),self.assertRaises(ValueError):validate(changed)
    def test_duplicate_stale_count_and_start_only_are_refused(self):
        text=fabricated_success();line=next(x for x in text.splitlines() if x.startswith('✔ Test savedNumerical'))
        for changed in [text+'\n'+line+'\n',text.replace('117 tests in 19 suites','112 tests in 18 suites'),
            text.replace(line,'◇ Test savedNumericalEvidenceDirectoryIsExplicitLocalAndOptional() started.')]:
            with self.assertRaises(ValueError):validate(changed)
    def test_parameterized_wrong_count_and_duplicate_case_refused(self):
        text=fabricated_success();case=next(x for x in text.splitlines() if 'acknowledge → false' in x)
        for changed in [text.replace('with 2 test cases passed','with 1 test cases passed'),text+'\n'+case+'\n']:
            with self.assertRaises(ValueError):validate(changed)
if __name__=='__main__':unittest.main()
