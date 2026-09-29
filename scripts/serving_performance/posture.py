"""Validate the fixed recovery policy and observed posture of measured trials."""
import math


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


def nominal_snapshot(value):
    return (isinstance(value, dict) and type(value.get('thermalState')) is int
            and value['thermalState'] == 0 and value.get('lowPowerMode') is False)


def nominal_trial(value):
    posture = value.get('posture')
    return (isinstance(posture, dict) and nominal_snapshot(posture.get('before'))
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
    return (all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
                for v in (waited, stable)) and 20000 <= waited <= 180000 and 5000 <= stable <= waited
            and nominal_snapshot(value.get('after')))
