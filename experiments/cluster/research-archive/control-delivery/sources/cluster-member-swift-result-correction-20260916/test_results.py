"""Small pure parser controls over the exact retained output; no Swift invocation."""
import unittest
from context import RETRY
from corrected_results import validate_swift_results, MEMBER_METHODS, NATIVE_PAIR_METHODS

TITLE = '"Real WebSocket requires explicit member acknowledgment"'
RAW = (RETRY / 'swift-tests-2/execution.stdout').read_text() + '\n' + (RETRY / 'swift-tests-2/execution.stderr').read_text()
COMPLETE = next(line for line in RAW.splitlines() if line.startswith('✔ Test ' + TITLE))
STARTS = ['◇ Test case passing 1 argument acknowledge → ' + value + ' to ' + TITLE + ' started.'
          for value in ('false', 'true')]


class ResultChecks(unittest.TestCase):
    def reject(self, text):
        with self.assertRaises(ValueError):
            validate_swift_results(text)

    def test_actual_two_case_completion(self):
        result = validate_swift_results(RAW)
        self.assertEqual((result['testsPassed'], result['suitesPassed']), (78, 12))
        self.assertEqual(result['parameterizedMemberCasesPassed'], 2)
        self.assertEqual(result['parameterizedMemberCaseValues'], [False, True])
        self.assertEqual(result['nativePairMethodsPassed'], 2)

    def test_start_only_and_missing_each_case(self):
        for line in [COMPLETE] + STARTS:
            with self.subTest(line=line):
                self.reject(RAW.replace(line + '\n', ''))

    def test_wrong_count_and_unrecognized_completion(self):
        for new in ['with 1 test cases', 'with 3 test cases', 'with 02 test cases',
                    'with 2 test case', 'with 2 test cases unexpectedly']:
            with self.subTest(new=new):
                self.reject(RAW.replace('with 2 test cases', new))
        self.reject(RAW.replace(' with 2 test cases', ''))

    def test_duplicate_case_and_completion(self):
        for line in [COMPLETE] + STARTS:
            with self.subTest(line=line):
                self.reject(RAW + line + '\n')

    def test_cases_must_precede_completion(self):
        for line in STARTS:
            with self.subTest(line=line):
                self.reject(RAW.replace(line + '\n', '') + line + '\n')

    def test_failure_record_refuses_even_with_pass_summary(self):
        self.reject(RAW + '✘ Test ' + TITLE + ' recorded an issue.\n')
        self.reject(RAW + '✘ Test unrelated() failed after 0.001 seconds.\n')

    def test_required_member_native_checks_cannot_be_start_only(self):
        for name in MEMBER_METHODS + NATIVE_PAIR_METHODS:
            passed = next(line for line in RAW.splitlines() if line.startswith('✔ Test ' + name + '() '))
            with self.subTest(name=name):
                self.reject(RAW.replace(passed + '\n', ''))
                self.reject(RAW + passed + '\n')

    def test_missing_duplicate_or_malformed_summary(self):
        summary = next(line for line in RAW.splitlines() if line.startswith('✔ Test run with '))
        for text in [RAW.replace(summary, ''), RAW + summary + '\n',
                     RAW.replace('12 suites passed after', '12 suites eventually passed after')]:
            self.reject(text)


if __name__ == '__main__':
    unittest.main()
