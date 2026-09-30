"""Synthetic posture traces for verifier tests; never hardware evidence."""


def observations(duration):
    times = list(range(0, int(duration) + 1, 500))
    if times[-1] != duration:
        times.append(duration)
    return [{"elapsedMilliseconds": t, "snapshot": {
        "thermalState": 0, "lowPowerMode": False, "powerSource": "ac",
        "automaticPower": True, "powerPolicyAgeMilliseconds": 0}} for t in times]


def trial_posture(duration=2000):
    samples = observations(duration)
    return {"before": samples[0]["snapshot"].copy(), "after": samples[-1]["snapshot"].copy(),
            "observations": samples, "droppedObservations": 0,
            "worstThermalState": 0, "lowPowerObserved": False}


def cooldown():
    value = trial_posture(20000)
    value.pop("worstThermalState")
    value.pop("lowPowerObserved")
    value.update(passed=True, waitedMilliseconds=20000, nominalStableMilliseconds=20000,
                 minimumMilliseconds=20000, stableMilliseconds=5000, recoveryLimitMilliseconds=180000)
    return value
