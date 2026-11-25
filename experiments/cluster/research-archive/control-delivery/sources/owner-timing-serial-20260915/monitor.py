"""Bounded observational sampler; native workers retain their own resource gates."""
import json
import select
import sys
import time
from reference_resources import sample_local, validate_local

started = time.monotonic()
for ordinal in range(1400):
    record = {"schema": "native_owner_resource_observation_v1", "ordinal": ordinal}
    try:
        record.update(sample_local())
        validate_local(record)
        record["admissible"] = True
    except Exception as error:
        record["admissible"] = False
        record["error"] = type(error).__name__ + ": " + str(error)
    print(json.dumps(record, sort_keys=True), flush=True)
    if time.monotonic() - started >= 330:
        break
    if select.select([sys.stdin], [], [], 0.25)[0]:
        if sys.stdin.readline() != "stop\n":
            raise SystemExit(2)
        break
