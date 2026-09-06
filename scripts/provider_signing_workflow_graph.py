"""Parsed, fail-closed contract for CI's manual signing-validation route.

Ruby's standard-library YAML parser avoids reimplementing YAML or installing a
parser during this CPU-only source check. No workflow command is executed.
"""
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CALL_JOB = "provider-signing-validation"
CALL_PATH = "./.github/workflows/provider-signing-validation.yml"
SIGNING_SECRETS = (
    "APPLE_CERTIFICATE_P12", "APPLE_CERTIFICATE_PASSWORD", "PROVISIONING_PROFILE_BASE64",
    "APPLE_ID", "APPLE_APP_PASSWORD",
)
MANUAL = "${{ github.event_name == 'workflow_dispatch' }}"
ORDINARY = "${{ github.event_name != 'workflow_dispatch' }}"
CACHE = "${{ github.event_name != 'workflow_dispatch' && (github.event_name == 'push') }}"
READ_ONLY = {"contents": "read", "actions": "read"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parsed_yaml(path):
    program = "v = YAML.safe_load(File.read(ARGV[0])); v['on'] = v.delete(true) if v.key?(true); puts JSON.generate(v)"
    result = subprocess.run(["ruby", "-ryaml", "-rjson", "-e", program, str(path)],
                            check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def canonical_sha256(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def load_contract(root=ROOT):
    baseline = json.loads((root / "scripts/fixtures/provider-signing-routing-baseline.json").read_text())
    return (parsed_yaml(root / ".github/workflows/ci.yml"),
            parsed_yaml(root / ".github/workflows/provider-signing-validation.yml"), baseline)


def secret_references(value):
    return set(re.findall(r"secrets\.([A-Z][A-Z0-9_]*)", json.dumps(value)))


def validate(ci, signing, baseline):
    require({k: v for k, v in ci.items() if k not in ("on", "jobs")} == baseline["ci"]["top"],
            "CI top-level behavior changed")
    events = dict(ci["on"])
    manual = events.pop("workflow_dispatch", None)
    require(events == baseline["ci"]["events"], "normal CI triggers changed")
    require(manual == baseline["signing"]["manual_event"], "manual inputs changed or gained defaults")
    require(set(ci["jobs"]) == set(baseline["ci"]["jobs"]) | {CALL_JOB}, "CI job graph changed")
    for name, expected in baseline["ci"]["jobs"].items():
        job = copy.deepcopy(ci["jobs"][name])
        old_if = expected["if"]
        require(old_if in (None, "github.event_name == 'push'"), "unsupported baseline condition")
        guard = ORDINARY if old_if is None else CACHE
        require(job.get("if") == guard, "manual isolation guard changed: " + name)
        if old_if is None:
            del job["if"]
        else:
            job["if"] = old_if
        require(canonical_sha256(job) == expected["sha256"], "normal job definition changed: " + name)

    expected_call = {
        "name": "Provider signing validation (manual only)", "if": MANUAL, "uses": CALL_PATH,
        "permissions": READ_ONLY,
        "with": {key: "${{ inputs." + key + " }}" for key in ("source_sha", "version")},
        "secrets": {name: "${{ secrets." + name + " }}" for name in SIGNING_SECRETS},
    }
    require(ci["jobs"][CALL_JOB] == expected_call, "reusable caller route, inputs, permissions or secrets changed")
    require({k: v for k, v in signing.items() if k not in ("on", "jobs")} == baseline["signing"]["top"],
            "signing workflow top-level behavior changed")
    require(signing.get("permissions") == READ_ONLY, "signing permission escalation")
    require(set(signing["on"]) == {"workflow_dispatch", "workflow_call"}, "unexpected signing trigger")
    require(signing["on"]["workflow_dispatch"] == baseline["signing"]["manual_event"],
            "standalone manual entrypoint changed")
    require(signing["on"]["workflow_call"] == {
        "inputs": manual["inputs"], "secrets": {name: {"required": True} for name in SIGNING_SECRETS}},
        "reusable workflow inputs or five-secret contract changed")
    require(set(signing["jobs"]) == {"build", "signing"}, "unexpected signing job graph")
    for name, expected in baseline["signing"]["jobs"].items():
        require(canonical_sha256(signing["jobs"][name]) == expected, "signing job definition changed: " + name)
    require(not secret_references(signing["jobs"]["build"]), "signing secret reached build job")
    require(secret_references(signing["jobs"]["signing"]) == set(SIGNING_SECRETS),
            "signer secret allowlist changed")
    require(signing["jobs"]["signing"]["needs"] == "build", "signer no longer depends on unsigned build")


def condition_active(condition, event):
    """Only the three exact conditions accepted by validate are supported."""
    if condition == MANUAL:
        return event == "workflow_dispatch"
    if condition == ORDINARY:
        return event != "workflow_dispatch"
    if condition == CACHE:
        return event != "workflow_dispatch" and event == "push"
    raise ValueError("unsupported routing condition")


def expanded_ci_graph(ci, signing, baseline, event):
    validate(ci, signing, baseline)
    if event not in ci["on"]:
        return {}
    graph = {}
    for name, job in ci["jobs"].items():
        if not condition_active(job["if"], event):
            continue
        if name != CALL_JOB:
            graph[name] = copy.deepcopy(job)
        else:
            for child_name, child in signing["jobs"].items():
                node = copy.deepcopy(child)
                needs = node.get("needs")
                if needs is not None:
                    needs = [needs] if isinstance(needs, str) else needs
                    node["needs"] = [CALL_JOB + "/" + value for value in needs]
                graph[CALL_JOB + "/" + child_name] = node
    return graph


def preserved_files(root, baseline):
    for relative, expected in baseline["preserved_files"].items():
        require(hashlib.sha256((root / relative).read_bytes()).hexdigest() == expected,
                "preserved source changed: " + relative)


def snapshot(root=ROOT):
    ci, signing, baseline = load_contract(root)
    validate(ci, signing, baseline)
    preserved_files(root, baseline)
    graphs = {event: expanded_ci_graph(ci, signing, baseline, event)
              for event in ("push", "pull_request", "workflow_dispatch")}
    return {"schema": 1, "baseline_commit": baseline["source_commit"],
            "status": "validated", "event_job_graphs": graphs,
            "workflow_call_path": CALL_PATH, "secret_names": list(SIGNING_SECRETS),
            "secret_values_read": False, "normal_job_definitions_preserved": True,
            "signing_build_job_preserved": True,
            "signing_identity_revision": baseline["signing"].get("identity_revision")}


if __name__ == "__main__":
    print(json.dumps(snapshot(), indent=2))
