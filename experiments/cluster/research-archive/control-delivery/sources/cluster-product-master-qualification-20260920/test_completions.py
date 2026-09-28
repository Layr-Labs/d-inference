"""Staged parser controls only; synthetic logs make no product qualification claim."""
import unittest
from common import BASE, read
from completions import completion


def valid():
    c = read(BASE / 'test-coverage.json')
    return '\n'.join(c['parameterizedCaseStarts'] + ['✔ Test ' + label + ' passed after 0.001 seconds.' for label in c['completionLabels']] + ['✔ Test run with 192 tests in 30 suites passed after 1.001 seconds.'])


class CompletionControls(unittest.TestCase):
    def test_exact_named_completions(self):
        self.assertEqual(completion(valid())['passedTests'], 192)

    def test_summary_or_starts_alone_cannot_pass(self):
        with self.assertRaises(ValueError):
            completion('✔ Test run with 192 tests passed after 1.001 seconds.')

    def test_missing_duplicate_failed_and_wrong_count_refuse(self):
        text = valid()
        line = '✔ Test ' + read(BASE / 'test-coverage.json')['completionLabels'][0] + ' passed after 0.001 seconds.'
        for value in (text.replace(line, ''), text + '\n' + line, text + '\n✘ Test failed.', text.replace('with 2 test cases passed', 'with 3 test cases passed'), text.replace('with 192 tests', 'with 191 tests')):
            with self.assertRaises(ValueError):
                completion(value)

    def test_parameterized_missing_duplicate_and_wrong_value_refuse(self):
        text = valid()
        line = read(BASE / 'test-coverage.json')['parameterizedCaseStarts'][0]
        for value in (text.replace(line, ''), text + '\n' + line, text.replace('acknowledge → false', 'acknowledge → unknown')):
            with self.assertRaises(ValueError):
                completion(value)


if __name__ == '__main__':
    unittest.main()
