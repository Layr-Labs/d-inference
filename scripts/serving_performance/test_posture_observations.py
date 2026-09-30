import unittest

from .posture import nominal_trial, valid_cooldown
from .posture_fixtures import cooldown, trial_posture


class ContinuousPostureTests(unittest.TestCase):
    def test_intact_cooldown_and_full_trial_are_valid(self):
        self.assertTrue(valid_cooldown(cooldown()))
        self.assertTrue(nominal_trial(self.trial()))

    def trial(self):
        return {"rows": [{"elapsedMs": 2000}], "posture": trial_posture(),
                "thermalState": 0, "lowPowerMode": False}

    def test_ac_endpoints_do_not_hide_source_or_mode_roundtrips(self):
        for field, value in (("powerSource", "battery"), ("powerSource", None),
                              ("automaticPower", False), ("automaticPower", None),
                              ("powerPolicyAgeMilliseconds", 3000)):
            for kind in ("cooldown", "trial"):
                record = cooldown() if kind == "cooldown" else self.trial()
                posture = record if kind == "cooldown" else record["posture"]
                posture["observations"][1]["snapshot"][field] = value
                with self.subTest(field=field, value=value, kind=kind):
                    self.assertFalse(valid_cooldown(record) if kind == "cooldown" else nominal_trial(record))

    def test_gaps_drops_missing_samples_and_short_trial_coverage_fail(self):
        for mutation in (lambda p: p.pop("observations"),
                         lambda p: p.update(droppedObservations=1),
                         lambda p: p["observations"].__delitem__(slice(1, 3)),
                         lambda p: p["observations"][1].update(elapsedMilliseconds=0),
                         lambda p: p["observations"].pop()):
            record = self.trial()
            mutation(record["posture"])
            self.assertFalse(nominal_trial(record))
        record = self.trial()
        record["rows"][0]["elapsedMs"] = 2001
        self.assertFalse(nominal_trial(record))

    def test_nominal_recovery_is_recomputed_from_the_actual_trace(self):
        record = cooldown()
        record["observations"][-3]["snapshot"]["thermalState"] = 1
        self.assertFalse(valid_cooldown(record), "declared five seconds cannot hide a late thermal transition")
