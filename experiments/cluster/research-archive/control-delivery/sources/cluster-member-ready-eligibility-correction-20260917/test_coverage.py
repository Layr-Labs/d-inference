"""Parser controls use retained text and explicitly fabricated pass text, never claimed as tests."""
import hashlib,json,re,unittest
from pathlib import Path
from context import BASE
from coverage import validate

def original():
    proof=json.loads((BASE/'discovered-coverage.json').read_text());raw=Path(proof['sourceStdout']).read_bytes()
    if hashlib.sha256(raw).hexdigest()!=proof['sourceSHA256']:raise ValueError('Retained actual failed log changed')
    return raw.decode()

def fabricated_success():
    text=original()
    text=re.sub(r'(?m)^✘ Test .+ recorded an issue .+\n','',text)
    text=re.sub(r'(?m)^✘ Test (.+?) failed after ([0-9.]+) seconds with 1 issue\.$',r'✔ Test \1 passed after \2 seconds.',text)
    text=re.sub(r'(?m)^✘ Suite (.+?) failed after ([0-9.]+) seconds with 1 issue\.$',r'✔ Suite \1 passed after \2 seconds.',text)
    return text.replace('✘ Test run with 112 tests in 18 suites failed after 10.073 seconds with 2 issues.',
        '✔ Test run with 112 tests in 18 suites passed after 10.073 seconds.')

class CoverageTests(unittest.TestCase):
    def test_actual_failure_is_never_a_pass(self):
        with self.assertRaises(ValueError):validate(original())
    def test_all_112_and_parameterized_completions_required(self):
        self.assertEqual(validate(fabricated_success())['actualDiscoveredMethodsPassed'],112)
    def test_each_newly_discovered_inherited_case_is_required(self):
        proof=json.loads((BASE/'discovered-coverage.json').read_text())
        for label in proof['additionalInheritedLabels']:
            text=re.sub(r'(?m)^✔ Test '+re.escape(label)+r' passed after [^\n]+\n','',fabricated_success())
            with self.subTest(label=label),self.assertRaises(ValueError):validate(text)
    def test_duplicate_or_stale_total_refused(self):
        text=fabricated_success();line=next(x for x in text.splitlines() if x.startswith('✔ Test keyOnlyOwner'))
        for changed in [text+'\n'+line+'\n',text.replace('112 tests in 18 suites','107 tests in 18 suites')]:
            with self.assertRaises(ValueError):validate(changed)
if __name__=='__main__':unittest.main()
