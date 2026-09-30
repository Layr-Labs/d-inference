"""Validate the fixed recovery policy and observed posture of measured trials."""
import math
from .posture_observations import ac_observations, finite_nonnegative, nominal_ac_snapshot, nominal_observations


COOLED_DEADLINE_APPLICABILITY = {
    "minimum_whole_mac_quiescence_ms": 20000,
    "minimum_nominal_stability_ms": 5000,
    "power_mode": "automatic",
}


def cooled_deadline_applicability(value):
    """The measured recovery conditions must survive promotion into runtime policy."""
    return (isinstance(value, dict) and value == COOLED_DEADLINE_APPLICABILITY
            and all(type(value.get(key)) is int for key in
                    ("minimum_whole_mac_quiescence_ms", "minimum_nominal_stability_ms")))


def automatic_ac_run(provenance):
    """The current deadline-policy revision has AC-only measured authority."""
    before = provenance.get("power_posture_before")
    after = provenance.get("power_posture_after")
    return (isinstance(before, dict) and before == after
            and before.get("source") == "ac" and before.get("mode") == "automatic")


def nominal_snapshot(value):
    return nominal_ac_snapshot(value)


def nominal_trial(value):
    posture = value.get('posture')
    elapsed = [row.get('elapsedMs') for row in value.get('rows', [])]
    return (bool(elapsed) and all(finite_nonnegative(v) for v in elapsed)
            and nominal_observations(posture, max(elapsed))
            and nominal_snapshot(posture.get('before'))
            and nominal_snapshot(posture.get('after'))
            and type(posture.get('worstThermalState')) is int and posture['worstThermalState'] == 0
            and posture.get('lowPowerObserved') is False
            and value.get('lowPowerMode') is False and type(value.get('thermalState')) is int
            and value['thermalState'] == 0)


def valid_cooldown(value):
    if not isinstance(value, dict) or value.get('passed') is not True:
        return False
    for key, expected in (('minimumMilliseconds', 20000), ('stableMilliseconds', 5000),
                          ('recoveryLimitMilliseconds', 180000)):
        if type(value.get(key)) is not int or value[key] != expected:
            return False
    waited, stable = value.get('waitedMilliseconds'), value.get('nominalStableMilliseconds')
    observations = ac_observations(value)
    if observations is None or observations[-1]['elapsedMilliseconds'] != waited:
        return False
    stable_start = None
    for observation in observations:
        if nominal_snapshot(observation['snapshot']):
            if stable_start is None:
                stable_start = observation['elapsedMilliseconds']
        else:
            stable_start = None
    if stable_start is None or not finite_nonnegative(stable) or stable > waited - stable_start:
        return False
    return (all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
                for v in (waited, stable)) and 20000 <= waited <= 180000 and 5000 <= stable <= waited
            and nominal_snapshot(value.get('after')))
