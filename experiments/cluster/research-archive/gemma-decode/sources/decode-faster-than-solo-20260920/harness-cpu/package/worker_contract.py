"""Closed control/event envelope checks; no numerical or runtime attestation."""

from dataclasses import dataclass
import json
import re

SCHEMA = "qwen_resident_benchmark_worker_v1"
MAX_LINE = 8 * 1024 * 1024
MAX_OUTPUT = 16 * 1024 * 1024
SUFFIXES = (":warmup:0", ":measured:0", ":measured:1", ":measured:2")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def detached(value):
    return json.loads(json.dumps(value, allow_nan=False, ensure_ascii=True))


def encoded(value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    require(len(raw) <= 4096, "Control command exceeds 4 KiB")
    return raw + b"\n"


def _object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate event JSON key")
        result[key] = value
    return result


def decode(raw):
    def nonfinite(value):
        raise ValueError("Nonfinite event JSON literal: " + value)
    return json.loads(raw.decode("utf-8"), object_pairs_hook=_object, parse_constant=nonfinite)


@dataclass(frozen=True)
class WorkerSpec:
    argv: tuple
    env: dict
    role: str
    rank: object


def workers(value):
    require(type(value) in (list, tuple) and len(value) in (1, 2), "Expected solo or two rank workers")
    result = []
    for item in value:
        require(type(item) is WorkerSpec, "Expected explicit WorkerSpec")
        require(type(item.argv) in (list, tuple) and item.argv
                and all(type(x) is str and x and "\0" not in x for x in item.argv), "Invalid worker argv")
        require(type(item.env) is dict and all(type(k) is str and k and "=" not in k and "\0" not in k
                and type(v) is str and "\0" not in v for k, v in item.env.items()), "Invalid explicit worker environment")
        require(item.role in ("solo", "rank") and type(item.role) is str, "Invalid worker role")
        require((item.role == "solo" and item.rank is None)
                or (item.role == "rank" and type(item.rank) is int and item.rank in (0, 1)), "Invalid worker rank")
        result.append(WorkerSpec(tuple(item.argv), dict(item.env), item.role, item.rank))
    require([(x.role, x.rank) for x in result] in ([('solo', None)], [('rank', 0), ('rank', 1)]),
            "Worker roles/order differ from solo or rank0/rank1")
    return tuple(result)


def open_command(cohort_id, requests):
    require(type(cohort_id) is str and re.fullmatch(r"[A-Za-z0-9_.-]{1,64}:[A-Za-z0-9_.-]{1,64}", cohort_id),
            "Invalid cohort ID")
    require(type(requests) is list and len(requests) == 4, "Open requires four declared requests")
    rows, epochs = [], set()
    for index, row in enumerate(requests):
        require(type(row) is dict and set(row) == {"request_id", "epoch"}, "Invalid declared request fields")
        require(type(row['request_id']) is str and row['request_id'] == cohort_id + SUFFIXES[index], "Wrong declared request ID")
        epoch = row['epoch']
        require(type(epoch) is str and re.fullmatch(r"[0-9a-f]{32}", epoch) and epoch not in epochs, "Invalid or reused epoch")
        epochs.add(epoch)
        rows.append(dict(row))
    return dict(schema=SCHEMA, type="open", cohort_id=cohort_id, requests=rows)


def run_command(opened, ordinal, request):
    require(type(request) is dict and set(request) == {"request_id", "phase", "iteration"}, "Wrong run request fields")
    require(type(ordinal) is int and 0 <= ordinal < 4, "No next planned request")
    declared = opened['requests'][ordinal]
    require(type(request['request_id']) is str and request['request_id'] == declared['request_id']
            and type(request['phase']) is str and request['phase'] == ("warmup" if ordinal == 0 else "measured")
            and type(request['iteration']) is int and request['iteration'] == (0 if ordinal == 0 else ordinal - 1),
            "Request differs from the next declared step")
    return dict(schema=SCHEMA, type="run", cohort_id=opened['cohort_id'], sequence=ordinal + 1, **declared)


def event(raw, spec, expected_type, command):
    value = decode(raw)
    detached(value)  # Reject overflowing JSON floats as well as named NaN/Inf.
    require(type(value) is dict and set(value) == {"schema", "type", "cohort_id", "role", "rank", "record"},
            "Wrong worker event fields")
    require(value['schema'] == SCHEMA and value['type'] == expected_type and value['cohort_id'] == command['cohort_id']
            and value['role'] == spec.role and type(value['rank']) is type(spec.rank) and value['rank'] == spec.rank,
            "Wrong worker event identity/order")
    require(type(value['record']) is dict, "Worker event requires CPU record object")
    if expected_type == "result":
        record = value['record']
        require(set(record) == {"command", "step", "execution", "resourcesBeforeRequest", "resourcesAfterRequest"}
                and all(type(record[name]) is dict for name in record),
                "Wrong result record fields")
        require(encoded(record['command']) == encoded(command), "Result replays or substitutes a run command")
    return value
