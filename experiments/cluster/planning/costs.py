"""Closed, bounded input contract for per-chunk prefill cost scenarios."""

from dataclasses import dataclass
import re


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fields(value, names, where):
    require(type(value) is dict and set(value) == set(names.split()),
            f"{where}: unexpected or missing fields")
    return value


def integer(value, where, minimum=0, maximum=10**18):
    require(type(value) is int and minimum <= value <= maximum,
            f"{where}: expected bounded integer")
    return value


def label(value, where):
    require(type(value) is str and re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", value),
            f"{where}: expected compact identifier")
    return value


def sha(value, where):
    require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value),
            f"{where}: expected SHA-256")
    return value


@dataclass(frozen=True)
class Cost:
    low: int
    typical: int
    high: int

    @classmethod
    def read(cls, value, where):
        if value is None:
            return None
        fields(value, "low typical high", where)
        numbers = [integer(value[key], where) for key in ("low", "typical", "high")]
        require(numbers == sorted(numbers), f"{where}: unordered scenarios")
        return cls(*numbers)


def evidence(value, where):
    require(value["evidence_kind"] in ("assumed", "measured_services"),
            f"{where}: unsupported evidence kind")
    references = value["source_sha256"]
    require(type(references) is list and 1 <= len(references) <= 64,
            f"{where}: expected source references")
    for reference in references:
        sha(reference, where)
    require(len(set(references)) == len(references), f"{where}: duplicate references")


FRAME_FIELDS = "prepare_ns handoff_ns consume_ns completion_ns"
CANDIDATE_FIELDS = ("id plan_sha256 devices resource_layout policy evidence_kind "
                    "source_sha256 memory startup_ns return_token_ns frames")


def read_candidate(value, frame_count):
    fields(value, CANDIDATE_FIELDS, "candidate")
    label(value["id"], "candidate.id")
    sha(value["plan_sha256"], "candidate.plan_sha256")
    devices = value["devices"]
    require(type(devices) is list and len(devices) == 2, "candidate: two device identities required")
    for device in devices:
        label(device, "candidate.devices")
    require(value["resource_layout"] in ("independent_devices", "shared_device"),
            "candidate: unknown resource layout")
    require((devices[0] != devices[1]) == (value["resource_layout"] == "independent_devices"),
            "candidate: device identities disagree with resource layout")
    require(value["policy"] in ("serial_v1", "prompt_lookahead_one_v1"),
            "candidate: unsupported scheduling policy")
    evidence(value, "candidate")
    memory = value["memory"]
    require(type(memory) is list and len(memory) == 2, "candidate: two memory records required")
    parsed_memory = []
    for record in memory:
        fields(record, "peak_bytes budget_bytes", "memory")
        budget = record["budget_bytes"]
        parsed_memory.append((Cost.read(record["peak_bytes"], "peak_bytes"),
                              None if budget is None else integer(budget, "budget_bytes", minimum=1)))
    frames = value["frames"]
    require(type(frames) is list and len(frames) == frame_count,
            "candidate: frame costs must cover the exact prompt chunk count")
    parsed_frames = []
    for index, frame in enumerate(frames):
        fields(frame, FRAME_FIELDS, f"frame {index}")
        parsed_frames.append({name: Cost.read(frame[name], f"frame {index}.{name}")
                              for name in FRAME_FIELDS.split()})
    return dict(value, memory=parsed_memory, frames=parsed_frames,
                startup_ns=Cost.read(value["startup_ns"], "startup_ns"),
                return_token_ns=Cost.read(value["return_token_ns"], "return_token_ns"))


def read_profile(value):
    fields(value, "schema workload baseline candidates", "profile")
    require(value["schema"] == "cluster_prefill_costs_v1", "unsupported profile schema")
    workload = fields(value["workload"],
                      "artifact_sha256 tokens_sha256 arithmetic prompt_tokens chunk_tokens batch_size cache_mode",
                      "workload")
    for name in ("artifact_sha256", "tokens_sha256"):
        sha(workload[name], name)
    label(workload["arithmetic"], "arithmetic")
    prompt = integer(workload["prompt_tokens"], "prompt_tokens", 1, 1_048_576)
    chunk = integer(workload["chunk_tokens"], "chunk_tokens", 1, prompt)
    require(type(workload["batch_size"]) is int and workload["batch_size"] == 1
            and workload["cache_mode"] == "uncached", "only batch-one uncached prefill is modeled")
    frame_count = (prompt + chunk - 1) // chunk
    require(frame_count <= 2048, "too many chunks")
    baseline = value["baseline"]
    if baseline is not None:
        fields(baseline, "id device ttft_ns evidence_kind source_sha256", "baseline")
        label(baseline["id"], "baseline.id")
        label(baseline["device"], "baseline.device")
        evidence(baseline, "baseline")
        baseline = dict(baseline, ttft_ns=Cost.read(baseline["ttft_ns"], "baseline.ttft_ns"))
        require(baseline["ttft_ns"] is None or baseline["ttft_ns"].low > 0,
                "baseline: nonpositive time")
    candidates = value["candidates"]
    require(type(candidates) is list and 1 <= len(candidates) <= 128, "expected bounded candidates")
    require(len(candidates) * frame_count <= 8192, "too many candidate chunks")
    parsed = [read_candidate(candidate, frame_count) for candidate in candidates]
    require(len({candidate["id"] for candidate in parsed}) == len(parsed), "duplicate candidate id")
    return dict(value, baseline=baseline, candidates=parsed)
