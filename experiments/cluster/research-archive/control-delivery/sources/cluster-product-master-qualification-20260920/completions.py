"""Exact default-product completions, including both parameterized groups."""
import re
from common import BASE, read, require


def completion(text):
    contract = read(BASE / 'test-coverage.json')
    labels = re.findall(r'(?m)^✔ Test (.+?) passed after \d+(?:\.\d+)? seconds\.$', text)
    labels = [label for label in labels if not label.startswith('run with ')]
    summaries = re.findall(r'(?m)^✔ Test run with (\d+) tests(?: in \d+ suites)? passed after \d+(?:\.\d+)? seconds\.$', text)
    cases = re.findall(r'(?m)^◇ Test case passing .+ started\.$', text)
    require(sorted(labels) == contract['completionLabels'], 'Every exact default test must complete once; missing, extra or duplicate test')
    require(summaries == [str(contract['testCount'])], 'Exact single terminal test summary required')
    require(sorted(cases) == contract['parameterizedCaseStarts'], 'Exact five parameterized case starts required')
    require('✘' not in text, 'Failed or skipped Swift Testing test/suite')
    return dict(passedTests=len(labels), exactCompletions=True, parameterizedCases=len(cases), summaryCount=int(summaries[0]))
