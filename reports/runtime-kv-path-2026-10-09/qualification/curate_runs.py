#!/usr/bin/env python3
"""Keep compact measurements and bind them to the unmodified raw evidence."""
import argparse
import hashlib
import json
import math
from pathlib import Path

from qualification_environment import validate_environment
from suite_inputs import PreparedSuite, validate_report_input


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def execution_artifacts(report, mode, expected, path):
    if mode == "scores":
        identity = report
        fields = ("executableSHA256", "metallibSHA256")
    elif mode in ("retrieval", "arithmetic", "program", "long_retrieval"):
        identity = report.get("runtimeIdentity")
        fields = ("binary_sha256", "metallib_sha256")
    else:
        raise RuntimeError("Unsupported parsed report mode: " + str(mode))
    result = {}
    for artifact, field, canonical in zip(
            ("darkbloom", "mlx.metallib"), fields,
            ("executableSHA256", "metallibSHA256")):
        actual = identity.get(field) if isinstance(identity, dict) else None
        declared = expected.get(artifact)
        for value in (actual, declared):
            if (not isinstance(value, str) or len(value) != 64
                    or any(c not in "0123456789abcdef" for c in value)):
                raise RuntimeError("Missing or invalid execution artifact identity: " + str(path))
        if actual != declared:
            raise RuntimeError("Execution artifact mismatch: " + str(path))
        # A second envelope cannot hide a conflicting identity or provide a
        # fallback for the required schema selected by the measured mode.
        alternate = report.get("runtimeIdentity") if mode == "scores" else report
        if mode == "scores" and "runtimeIdentity" in report and not isinstance(alternate, dict):
            raise RuntimeError("Missing or invalid execution artifact identity: " + str(path))
        alternate_field = (
            "binary_sha256" if artifact == "darkbloom" else "metallib_sha256"
        ) if mode == "scores" else canonical
        if isinstance(alternate, dict) and alternate_field in alternate:
            if alternate[alternate_field] != actual:
                raise RuntimeError("Conflicting execution artifact identity: " + str(path))
        result[canonical] = actual
    return result


def evidence_label(entry):
    label = entry["modelID"].replace("/", "--") + "-" + entry["mode"] + "-" + entry["requestedPrecision"]
    return label + ("-mtp" if "--runtime-mtp" in entry["command"] else "")


def bound_suite(directory, manifest):
    schema = manifest.get("schema", 1)
    if type(schema) is not int or schema not in (1, 2):
        raise RuntimeError("Unsupported qualification run schema")
    if schema == 1:
        if "qualification" in manifest:
            raise RuntimeError("Legacy run cannot claim a scrubbed qualification environment")
        return None
    binding = manifest["qualification"]
    validate_environment(binding["environment"])
    if sha(directory / "provider-config.toml") != binding["configSHA256"]:
        raise RuntimeError("Retained qualification config changed")
    prepared = PreparedSuite(directory / "inputs")
    if prepared.digest != binding["suiteSHA256"]:
        raise RuntimeError("Retained qualification suite changed")
    return prepared


def validate_bound_input(report, entry, prepared, manifest, legacy_suites):
    if prepared is not None:
        identity, _, score_document = prepared.select(entry["modelID"], entry["mode"])
        if entry.get("inputIdentity") != identity:
            raise RuntimeError("Run input identity differs from retained prepared suite")
        digest = manifest["qualification"]["configSHA256"]
        if entry.get("configBeforeSHA256") != digest or entry.get("configAfterSHA256") != digest:
            raise RuntimeError("Run config validation differs from retained snapshot")
        validate_report_input(report, entry["mode"], identity, score_document, entry["requestedPrecision"])
    elif legacy_suites:
        for suite in legacy_suites:
            try:
                identity, _, score_document = suite.select(entry["modelID"], entry["mode"])
                validate_report_input(report, entry["mode"], identity, score_document, entry["requestedPrecision"])
                return
            except (RuntimeError, KeyError, OSError):
                continue
        raise RuntimeError("Legacy report input does not match an explicit prepared suite")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--stages", nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--inputs", type=Path, nargs="+", help="Validate legacy schema1 inputs without claiming a scrubbed environment")
    args = parser.parse_args()
    stages = []
    legacy_suites = [PreparedSuite(path) for path in (args.inputs or [])]
    for name in args.stages:
        directory = args.root / name
        manifest_path = directory / "run.json"
        manifest = json.loads(manifest_path.read_text())
        prepared = bound_suite(directory, manifest)
        results = []
        for original in manifest["results"]:
            entry = {key: value for key, value in original.items()
                     if key not in ("outputText", "diagnosticTop1")}
            label = evidence_label(entry)
            raw = directory / (label + ".json")
            log = directory / (label + ".log")
            if sha(raw) != entry["jsonSHA256"] or sha(log) != entry["logSHA256"]:
                raise RuntimeError("Retained evidence changed: " + str(raw))
            entry["rawJSON"] = name + "/" + raw.name
            entry["rawLog"] = name + "/" + log.name
            if entry.get("reportParsed"):
                report = json.loads(raw.read_text())
                # The serving JSON does not always project these into run.json.
                for field in ("executableSHA256", "metallibSHA256", "inputSHA256",
                              "concurrency", "kvCapacityBytes", "productionGrant"):
                    if field in report:
                        entry[field] = report[field]
                entry.update(execution_artifacts(
                    report, entry["mode"], manifest["candidateArtifacts"], raw))
                validate_bound_input(report, entry, prepared, manifest, legacy_suites)
                if entry["mode"] == "scores":
                    diagnostic = report["diagnostic"]
                    repeated = report["repeatedDiagnostic"]
                    records = diagnostic["records"]
                    entry["diagnosticChecks"] = {
                        "forcedTokenCount": len(records),
                        "promptTokenCount": len(report["input"]["promptTokens"]),
                        "finiteLogits": all(record["nanCount"] == 0
                                            and record["infiniteCount"] == 0
                                            for record in records),
                        "finiteMeanNLL": math.isfinite(report["meanForcedTokenNLL"]),
                        "plainTop1MatchesDiagnostic": report["plainTop1"] == diagnostic["top1"],
                        "repeatBitIdentical": diagnostic == repeated,
                    }
                    peers = [peer for peer in manifest["results"]
                             if peer["modelID"] == entry["modelID"] and peer["mode"] == "scores"
                             and peer["requestedPrecision"] == "native" and peer.get("reportParsed") is True]
                    if len(peers) > 1:
                        raise RuntimeError("Ambiguous native score manifest peer: " + str(raw))
                    if entry["requestedPrecision"] != "native" and peers:
                        peer = peers[0]
                        other = directory / (evidence_label(peer) + ".json")
                        if sha(other) != peer["jsonSHA256"]:
                            raise RuntimeError("Retained native peer evidence changed: " + str(other))
                        native = json.loads(other.read_text())
                        execution_artifacts(native, "scores", manifest["candidateArtifacts"], other)
                        validate_bound_input(native, peer, prepared, manifest, legacy_suites)
                        if native["input"] != report["input"]:
                            raise RuntimeError("Teacher contexts differ: " + str(raw))
                        expected_top1 = native["diagnostic"]["top1"]
                        observed_top1 = diagnostic["top1"]
                        if len(expected_top1) != len(observed_top1):
                            raise RuntimeError("Teacher token counts differ: " + str(raw))
                        entry["diagnosticChecks"]["nativeTop1Matches"] = sum(
                            left == right for left, right in zip(expected_top1, observed_top1))
            results.append(entry)
        stage = {
            "name": name, "sourceDigest": manifest["candidateSourceDigest"],
            "artifacts": manifest["candidateArtifacts"],
            "runManifestSHA256": sha(manifest_path), "results": results,
        }
        if prepared is not None:
            stage["qualification"] = manifest["qualification"]
        control = directory / "control.json"
        if control.exists():
            stage["control"] = json.loads(control.read_text())
            stage["controlSHA256"] = sha(control)
        stages.append(stage)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({
        "schema": 1,
        "scope": "Retained real model measurements, including failed/superseded stages. "
                 "The dated report selects valid cohorts; these are narrow synthetic probes.",
        "stages": stages,
    }, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"stages": len(stages), "results": sum(len(s["results"]) for s in stages),
                      "outputSHA256": sha(args.output)}))


if __name__ == "__main__":
    main()
