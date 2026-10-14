#!/usr/bin/env python3
"""Keep compact measurements and bind them to the unmodified raw evidence."""
import argparse
import hashlib
import json
import math
from pathlib import Path

from qualification_environment import validate_environment
from suite_inputs import PreparedSuite, require_hash, validate_report_input


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


def output_object(text):
    decoder = json.JSONDecoder()
    objects = []
    for index, character in enumerate(text):
        if character != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            objects.append(value)
    return objects[-1] if objects else None


def report_projection(report, mode, identity=None):
    result = {key: report[key] for key in (
        "resolvedBackend", "kvQuantization", "finishReason", "promptTokenCount",
        "completionTokenCount", "firstTokenMilliseconds", "totalMilliseconds",
        "peakMLXMemoryBytes", "preRequestActiveMemoryBytes", "peakMLXMemoryDeltaBytes",
        "peakObservedKVBytesInUse", "peakObservedPagedCommittedBytes",
        "peakObservedPagedLivePageBytes", "mtpRequested", "mtpActive", "mtpMetrics",
        "assistantIdentity", "meanForcedTokenNLL", "status", "inconclusiveReasons",
        "verifiedModelAggregateSHA256", "executableSHA256", "metallibSHA256",
        "inputSHA256", "concurrency", "kvCapacityBytes", "productionGrant",
    ) if key in report}
    if identity is not None:
        result["identityPassed"] = (
            report["verifiedModelAggregateSHA256"] == identity["expectedModelAggregateSHA256"]
            and report["resolvedBackend"] == "paged"
        )
    if mode == "scores":
        result["diagnosticTop1"] = report["diagnostic"]["top1"]
    else:
        answer = output_object(report["text"].rsplit("</think>", 1)[-1])
        result.update(outputText=report["text"], answer=answer)
        if identity is not None:
            result["taskPassed"] = report["finishReason"] == "stop" and answer == identity["expected"]
    return result


def assistant_identity(report, files=None, previous=None):
    identity = report.get("assistantIdentity")
    if (report.get("mtpRequested") is not True or report.get("mtpActive") is not True
            or not isinstance(identity, dict)
            or any(not isinstance(value, str) for value in identity.values())):
        raise RuntimeError("Missing active MTP assistant identity")
    expected = None
    if files is not None:
        if not isinstance(files, dict) or not 2 <= len(files) <= 64:
            raise RuntimeError("Invalid assistant snapshot inventory")
        config_hash = require_hash(files["config.json"])
        expected = {"source": "local", "revision": "local-" + config_hash[:16],
                    "config_sha256": config_hash}
        for name, digest in files.items():
            if name != "config.json":
                if Path(name).name != name or not name.endswith(".safetensors"):
                    raise RuntimeError("Invalid assistant snapshot filename")
                expected["weight_sha256." + name] = require_hash(digest)
    if identity.get("source") == "local":
        if expected is None:
            raise RuntimeError("Local MTP assistant has no frozen snapshot")
        if identity != expected:
            raise RuntimeError("Reported assistant differs from frozen snapshot")
    elif identity.get("source") == "inline":
        config_hash = require_hash(identity.get("config_sha256"))
        index_hash = require_hash(identity.get("inline_index_sha256"))
        if identity.get("revision") != "inline-" + config_hash[:8] + "-" + index_hash[:8]:
            raise RuntimeError("Invalid inline assistant identity")
    else:
        raise RuntimeError("Requested assistant has no local or inline identity")
    if previous is not None and identity != previous:
        raise RuntimeError("MTP assistant identity changed between arms")
    return identity


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
        return identity
    elif legacy_suites:
        for suite in legacy_suites:
            try:
                identity, _, score_document = suite.select(entry["modelID"], entry["mode"])
                validate_report_input(report, entry["mode"], identity, score_document, entry["requestedPrecision"])
                return identity
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
        assistant = manifest.get("qualification", {}).get("assistant")
        assistant_identities = {}
        results = []
        for original in manifest["results"]:
            entry = {key: value for key, value in original.items()
                     if key in ("modelID", "mode", "requestedPrecision", "command", "exitCode", "processSeconds",
                                "jsonSHA256", "logSHA256", "inputIdentity", "configBeforeSHA256",
                                "configAfterSHA256", "reportParsed", "parseError")}
            label = evidence_label(entry)
            raw = directory / (label + ".json")
            log = directory / (label + ".log")
            if sha(raw) != entry["jsonSHA256"] or sha(log) != entry["logSHA256"]:
                raise RuntimeError("Retained evidence changed: " + str(raw))
            entry["rawJSON"] = name + "/" + raw.name
            entry["rawLog"] = name + "/" + log.name
            if entry.get("reportParsed"):
                report = json.loads(raw.read_text())
                artifacts = execution_artifacts(report, entry["mode"], manifest["candidateArtifacts"], raw)
                identity = validate_bound_input(report, entry, prepared, manifest, legacy_suites)
                entry.update(report_projection(report, entry["mode"], identity))
                entry.pop("outputText", None)
                entry.pop("diagnosticTop1", None)
                entry.update(artifacts)
                command = entry["command"]
                if entry["mode"] != "scores" and (assistant is not None or "--runtime-mtp" in command
                                                  or report.get("mtpRequested") is True
                                                  or report.get("mtpActive") is True):
                    if "--runtime-mtp" not in command:
                        raise RuntimeError("Run MTP request differs from raw report")
                    if prepared is not None and assistant is None:
                        raise RuntimeError("Missing run MTP assistant binding")
                    files = assistant.get("files") if assistant is not None else None
                    if ("--runtime-assistant-directory" in command
                            or assistant is not None and ("files" in assistant or "path" in assistant)):
                        if (files is None or "--runtime-assistant-directory" not in command
                                or command.index("--runtime-assistant-directory") + 1 >= len(command)
                                or command[command.index("--runtime-assistant-directory") + 1] != assistant["path"]):
                            raise RuntimeError("Run assistant path differs from frozen snapshot")
                    assistant_identities[entry["modelID"]] = assistant_identity(
                        report, files, assistant_identities.get(entry["modelID"]))
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
        if assistant is not None and assistant.get("identities") != assistant_identities:
            raise RuntimeError("Run assistant identities differ from raw reports")
        stage = {
            "name": name, "sourceDigest": manifest["candidateSourceDigest"],
            "artifacts": manifest["candidateArtifacts"],
            "resources": manifest.get("candidateResources", {}),
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
