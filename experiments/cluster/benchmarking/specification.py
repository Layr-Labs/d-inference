"""Pure fixed-workload study specification and balanced cohort schedule.

Identities are caller declarations. Validation does not attest hardware,
tokenization, representative inputs, runtime eligibility or execution readiness.
This module opens no files and executes no workloads.
"""

import hashlib
import re


PROMPT_COUNT = 10
TOKEN_COUNT = 8192
BATCH_SIZE = 1
WARMUP_COUNT = 1
MEASURED_RUNS = 3
ORDER_DOMAIN = b"cluster_prefill_study_prompt_order_v1\0"
_FIELDS = frozenset(("schema", "study_id", "seed", "artifact_sha256",
                     "configuration_sha256", "numerical_policy", "tokenizer_sha256",
                     "chunk_size", "prompts", "conditions"))
_FIXED = dict(token_count=TOKEN_COUNT, batch_size=BATCH_SIZE,
              warmup_count=WARMUP_COUNT, measured_runs=MEASURED_RUNS)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _fields(value, names, where):
    _require(type(value) is dict and set(value) == set(names),
             where + ": unexpected or missing fields")


def _label(value, where):
    _require(type(value) is str and re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", value),
             where + ": expected a colon-free ASCII label of at most 64 characters")
    return value


def _sha(value, where):
    _require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value),
             where + ": expected lowercase SHA-256")
    return value


def _integer(value, low, high, where):
    _require(type(value) is int and low <= value <= high,
             where + ": expected bounded integer")
    return value


def read_study(document):
    """Validate the raw-only closed input schema and return detached metadata.

    Prompt rows are normalized by ID and conditions by solo/distributed role.
    The four fixed output constants are not accepted as raw input knobs.
    """
    _fields(document, _FIELDS, "study")
    _require(document["schema"] == "cluster_prefill_study_v1", "unsupported study schema")
    study_id = _label(document["study_id"], "study_id")
    seed = _integer(document["seed"], 0, 2**63 - 1, "seed")
    chunk = _integer(document["chunk_size"], 1, TOKEN_COUNT, "chunk_size")
    policy = document["numerical_policy"]
    _require(type(policy) is str and 1 <= len(policy) <= 128 and policy.strip()
             and all(32 <= ord(character) <= 126 for character in policy),
             "numerical_policy: expected nonblank printable ASCII of at most 128 characters")
    pins = {name: _sha(document[name], name) for name in
            ("artifact_sha256", "configuration_sha256", "tokenizer_sha256")}
    prompts = document["prompts"]
    _require(type(prompts) is list and len(prompts) == PROMPT_COUNT,
             "study requires exactly ten prompts")
    parsed_prompts = []
    for row in prompts:
        _fields(row, ("id", "prompt_sha256", "origin_sha256"), "prompt")
        parsed_prompts.append(dict(id=_label(row["id"], "prompt.id"),
            prompt_sha256=_sha(row["prompt_sha256"], "prompt.prompt_sha256"),
            origin_sha256=_sha(row["origin_sha256"], "prompt.origin_sha256")))
    _require(len({row["id"] for row in parsed_prompts}) == PROMPT_COUNT,
             "duplicate prompt ID")
    _require(len({row["prompt_sha256"] for row in parsed_prompts}) == PROMPT_COUNT,
             "duplicate raw prompt SHA-256")
    conditions = document["conditions"]
    _require(type(conditions) is list and len(conditions) == 2,
             "study requires exactly two conditions")
    parsed_conditions = []
    for row in conditions:
        _fields(row, ("id", "role", "runtime_identity_sha256", "device_ids"), "condition")
        role = row["role"]
        _require(type(role) is str and role in ("solo", "distributed"), "unknown condition role")
        devices = row["device_ids"]
        _require(type(devices) is list and len(devices) == (1 if role == "solo" else 2),
                 "condition device count differs from its role")
        parsed_devices = [_label(device, "device_id") for device in devices]
        _require(len(set(parsed_devices)) == len(parsed_devices), "duplicate condition device ID")
        parsed_conditions.append(dict(id=_label(row["id"], "condition.id"), role=role,
            runtime_identity_sha256=_sha(row["runtime_identity_sha256"], "runtime_identity_sha256"),
            device_ids=parsed_devices))
    _require(len({row["id"] for row in parsed_conditions}) == 2, "duplicate condition ID")
    roles = {row["role"]: row for row in parsed_conditions}
    _require(set(roles) == {"solo", "distributed"}, "one solo and one distributed condition required")
    _require(roles["solo"]["device_ids"][0] in roles["distributed"]["device_ids"],
             "solo device must belong to the distributed device pair")
    return dict(schema="cluster_prefill_study_v1", study_id=study_id, seed=seed,
                numerical_policy=policy, chunk_size=chunk,
                prompts=sorted(parsed_prompts, key=lambda row: row["id"]),
                conditions=[roles["solo"], roles["distributed"]], **pins, **_FIXED)


def make_schedule(study):
    """Return 20 fresh cohort dicts, validating raw or normalized study input.

    Hash ordering is domain + decimal seed + NUL + ASCII prompt ID, with ID as
    the collision tie-breaker. Each adjacent pair covers one prompt; solo comes
    first at even prompt indices and distributed first at odd indices. Device
    list order is retained and is not interpreted as hardware attestation.
    """
    _require(type(study) is dict, "study: expected object")
    if set(study) == _FIELDS | set(_FIXED):
        for name, value in _FIXED.items():
            _require(type(study[name]) is int and study[name] == value,
                     "normalized study changed fixed " + name)
        study = {name: study[name] for name in _FIELDS}
    checked = read_study(study)
    prefix = ORDER_DOMAIN + str(checked["seed"]).encode("ascii") + b"\0"
    prompts = sorted(checked["prompts"], key=lambda row:
                     (hashlib.sha256(prefix + row["id"].encode("ascii")).digest(), row["id"]))
    schedule = []
    for index, prompt in enumerate(prompts):
        conditions = checked["conditions"] if index % 2 == 0 else checked["conditions"][::-1]
        for condition in conditions:
            cohort_id = prompt["id"] + ":" + condition["id"]
            requests = [dict(request_id=cohort_id + ":warmup:0", phase="warmup", iteration=0)]
            requests.extend(dict(request_id=cohort_id + ":measured:" + str(iteration),
                                 phase="measured", iteration=iteration)
                            for iteration in range(MEASURED_RUNS))
            schedule.append(dict(cohort_id=cohort_id, prompt_id=prompt["id"],
                                 condition_id=condition["id"], prompt_sha256=prompt["prompt_sha256"],
                                 requests=requests))
    return schedule
