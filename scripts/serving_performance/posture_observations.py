"""Validate the actual 500-ms posture stream, including gaps and endpoints."""
import math


def finite_nonnegative(value):
    return (type(value) in (int, float) and math.isfinite(value) and value >= 0)


def ac_observations(record):
    if not isinstance(record, dict) or type(record.get("droppedObservations")) is not int or record["droppedObservations"] != 0:
        return None
    observations = record.get("observations")
    if not isinstance(observations, list) or not 2 <= len(observations) <= 2048:
        return None
    previous = None
    for observation in observations:
        if not isinstance(observation, dict):
            return None
        elapsed, snapshot = observation.get("elapsedMilliseconds"), observation.get("snapshot")
        if (not finite_nonnegative(elapsed) or not isinstance(snapshot, dict)
                or snapshot.get("powerSource") != "ac"
                or snapshot.get("automaticPower") is not True
                or not finite_nonnegative(snapshot.get("powerPolicyAgeMilliseconds"))
                or snapshot["powerPolicyAgeMilliseconds"] >= 3000
                or type(snapshot.get("thermalState")) is not int
                or snapshot["thermalState"] not in (0, 1, 2, 3)
                or type(snapshot.get("lowPowerMode")) is not bool):
            return None
        if (previous is None and elapsed != 0) or (previous is not None and not 0 < elapsed - previous <= 1000):
            return None
        previous = elapsed
    if (record.get("before") != observations[0]["snapshot"]
            or record.get("after") != observations[-1]["snapshot"]):
        return None
    return observations


def nominal_ac_snapshot(value):
    return (isinstance(value, dict) and type(value.get("thermalState")) is int
            and value["thermalState"] == 0 and value.get("lowPowerMode") is False
            and value.get("powerSource") == "ac" and value.get("automaticPower") is True)


def nominal_observations(record, minimum_duration=0):
    observations = ac_observations(record)
    return (observations is not None and finite_nonnegative(minimum_duration)
            and observations[-1]["elapsedMilliseconds"] >= minimum_duration
            and all(nominal_ac_snapshot(o["snapshot"]) for o in observations))
