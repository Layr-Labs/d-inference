"""Staged parser controls only; no Go/server/database process is created."""
import copy
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'cluster-native-shared-hardware-go-qualification-draft-20260917'))
from command_results import REASON, SKIP, validate_command


class CommandResults(unittest.TestCase):
    package = 'github.com/eigeninference/d-inference/coordinator/cmd/coordinator'

    def fixture(self):
        names = [SKIP, 'TestNativeHardwareTrustOnlyHasNoCatalogAndServesTLS']
        events = [{'Package': self.package, 'Action': 'pass'},
                  {'Package': self.package, 'Test': SKIP, 'Action': 'output', 'Output': REASON},
                  {'Package': self.package, 'Test': SKIP, 'Action': 'skip'},
                  {'Package': self.package, 'Test': names[1], 'Action': 'pass'}]
        return events, {self.package: names}

    def test_exact_declared_skip_is_not_reported_as_pass(self):
        events, expected = self.fixture()
        self.assertEqual(validate_command(events, expected)[self.package][SKIP], 'skip')

    def test_another_skip_or_failure_or_missing_completion_refuses(self):
        for action in ('skip', 'fail', 'run'):
            events, expected = self.fixture(); events[-1]['Action'] = action
            with self.assertRaises(ValueError): validate_command(events, expected)

    def test_missing_changed_or_duplicate_reason_refuses(self):
        for action in ('remove', 'change', 'duplicate'):
            events, expected = self.fixture()
            if action == 'remove': del events[1]
            elif action == 'change': events[1]['Output'] = 'a different unavailable prerequisite\n'
            else: events.append(copy.deepcopy(events[1]))
            with self.assertRaises(ValueError): validate_command(events, expected)

    def test_unexpected_database_execution_and_duplicate_completion_refuse(self):
        events, expected = self.fixture(); events[2]['Action'] = 'pass'
        with self.assertRaises(ValueError): validate_command(events, expected)
        events, expected = self.fixture(); events.append(copy.deepcopy(events[2]))
        with self.assertRaises(ValueError): validate_command(events, expected)


if __name__ == '__main__': unittest.main()
