#!/usr/bin/env python3
"""Run a frozen candidate sequentially; keep every result, including failures."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import time


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


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


def evidence_path(stem, suffix):
    # Model IDs contain periods; replacing a suffix would collapse distinct
    # task/profile names such as qwen3.6-...-native and qwen3.6-...-balanced.
    return stem.parent / (stem.name + suffix)


def launch(command, output, timeout):
    started = time.monotonic()
    with evidence_path(output, ".json").open("wb") as stdout, evidence_path(output, ".log").open("wb") as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = "timeout"
    return code, time.monotonic() - started


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", type=pathlib.Path, required=True)
    parser.add_argument("--config", type=pathlib.Path, required=True)
    parser.add_argument("--inputs", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--models", nargs="+", required=True)
    parser.add_argument("--tasks", nargs="+", default=["retrieval", "arithmetic", "program", "long_retrieval"])
    parser.add_argument("--profiles", nargs="+", default=["native", "balanced"])
    parser.add_argument("--mtp", action="store_true")
    parser.add_argument("--assistant-directory", type=pathlib.Path)
    parser.add_argument("--scores", action="store_true")
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    if args.assistant_directory is not None and not args.mtp:
        parser.error("--assistant-directory requires --mtp")
    suite = json.loads((args.inputs / "suite.json").read_text())
    receipt = json.loads((args.candidate / "source-receipt.json").read_text())
    for name, expected in receipt["artifacts"].items():
        if sha(args.candidate / name) != expected:
            raise RuntimeError("Frozen candidate changed: " + name)
    for name, expected in receipt.get("resources", {}).items():
        if sha(args.candidate / name) != expected:
            raise RuntimeError("Frozen candidate resource changed: " + name)
    args.output.mkdir(parents=True, exist_ok=True)
    results = []
    tasks = {task["id"]: task for task in suite["tasks"]}
    for model in args.models:
        safe = model.replace("/", "--")
        expected = json.loads((args.inputs / (safe + "-scores-input.json")).read_text())[
            "expectedModelAggregateSHA256"]
        modes = [task for task in args.tasks if task != "none"]
        if args.scores:
            modes.append("scores")
        for mode in modes:
            for profile in args.profiles:
                label = f"{safe}-{mode}-{profile}" + ("-mtp" if args.mtp else "")
                stem = args.output / label
                if evidence_path(stem, ".json").exists() or evidence_path(stem, ".log").exists():
                    raise RuntimeError("Will not overwrite existing evidence: " + label)
                command = [str(args.candidate / "darkbloom"), "benchmark", "--config", str(args.config),
                           "--model", model, "--kv-backend", "paged", "--kv-quantization", profile]
                if mode == "scores":
                    command += ["--teacher-forced-input", str(args.inputs / (safe + "-scores-input.json"))]
                else:
                    command += ["--runtime-generation", "--runtime-prompt-date", suite["renderDate"],
                                "--runtime-prompt-file", str(args.inputs / tasks[mode]["file"]),
                                "--max-tokens", str(tasks[mode]["maximumGeneratedTokens"])]
                    if args.mtp:
                        command.append("--runtime-mtp")
                        if args.assistant_directory is not None:
                            command += ["--runtime-assistant-directory", str(args.assistant_directory)]
                print(json.dumps({"started": label, "utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}), flush=True)
                code, elapsed = launch(command, stem, args.timeout)
                entry = {"modelID": model, "mode": mode, "requestedPrecision": profile,
                         "command": command, "exitCode": code, "processSeconds": elapsed,
                         "jsonSHA256": sha(evidence_path(stem, ".json")),
                         "logSHA256": sha(evidence_path(stem, ".log"))}
                try:
                    report = json.loads(evidence_path(stem, ".json").read_text())
                    entry["reportParsed"] = True
                    for key in ["resolvedBackend", "kvQuantization", "finishReason", "promptTokenCount",
                                "completionTokenCount", "firstTokenMilliseconds", "totalMilliseconds",
                                "peakMLXMemoryBytes", "preRequestActiveMemoryBytes", "peakMLXMemoryDeltaBytes",
                                "peakObservedKVBytesInUse", "peakObservedPagedCommittedBytes",
                                "peakObservedPagedLivePageBytes", "mtpRequested", "mtpActive", "mtpMetrics",
                                "assistantIdentity",
                                "meanForcedTokenNLL", "status", "inconclusiveReasons",
                                "verifiedModelAggregateSHA256", "executableSHA256", "metallibSHA256"]:
                        if key in report:
                            entry[key] = report[key]
                    entry["identityPassed"] = (
                        report["verifiedModelAggregateSHA256"] == expected
                        and report["resolvedBackend"] == "paged"
                        and report["kvQuantization"] == profile
                    )
                    if mode != "scores":
                        final = report["text"].rsplit("</think>", 1)[-1]
                        answer = output_object(final)
                        entry["outputText"] = report["text"]
                        entry["answer"] = answer
                        entry["taskPassed"] = (
                            report["finishReason"] == "stop" and answer == tasks[mode]["expected"]
                        )
                    else:
                        entry["diagnosticTop1"] = report["diagnostic"]["top1"]
                except (ValueError, KeyError) as error:
                    entry["reportParsed"] = False
                    entry["parseError"] = str(error)
                results.append(entry)
                manifest = {"schema": 1, "candidateSourceDigest": receipt["source_file_digest"],
                            "candidateArtifacts": receipt["artifacts"], "results": results}
                (args.output / "run.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
                print(json.dumps({"finished": label, "exitCode": code, "seconds": round(elapsed, 3),
                                  "taskPassed": entry.get("taskPassed"), "nll": entry.get("meanForcedTokenNLL")}), flush=True)
    if any(item["exitCode"] != 0 or not item["reportParsed"]
           or not item.get("identityPassed") for item in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
