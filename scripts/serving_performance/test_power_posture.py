import unittest

from .power_posture import parse_posture


class PowerPostureTests(unittest.TestCase):
    def test_current_source_selects_actual_policy(self):
        settings = "Battery Power:\n powermode 1\nAC Power:\n powermode 2\n"
        self.assertEqual(parse_posture(settings, "Now drawing from 'AC Power'\n")["mode"], "high")
        self.assertEqual(parse_posture(settings, "Now drawing from 'Battery Power'\n")["mode"], "low")
        self.assertEqual(parse_posture(settings.replace("powermode 2", "powermode 0"),
                                       "Now drawing from 'AC Power'\n")["mode"], "automatic")

    def test_low_power_disabled_is_insufficient_evidence(self):
        self.assertEqual(parse_posture("AC Power:\n lowpowermode 0\n", "Now drawing from 'AC Power'\n")["mode"], "unknown")
        self.assertEqual(parse_posture("AC Power:\n powermode 0\n", "unknown")["mode"], "unknown")
