#!/usr/bin/env python3
"""Run the direct token/cache probe with dedicated-host ownership and telemetry."""

import argparse
from datetime import date
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from run_radix_http import ranked_job, terminate
from radix_persistent_test_keys import (parse_persistent_test_key_arguments,
    persistent_test_key_provenance, validate_persistent_test_key_provenance)


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--model-directory", required=True)
    parser.add_argument("--input", required=True, help="Retained HTTP report.json")
    parser.add_argument("--output", required=True)
    parser.add_argument("--cache", choices=["on", "off"], default="on")
    parser.add_argument("--mtp", choices=["on", "off"], default="off")
    parser.add_argument("--gemma-mtp-verification", choices=["automatic", "serial_target"],
                        help="Explicit offline Gemma verifier control; production B1/cache-off only")
    parser.add_argument("--gemma-projection-tokens",
                        help="Capture actual layer-0 M1/M2 projections for exactly two token IDs; diagnostic overhead only")
    parser.add_argument("--kv-backend", choices=["auto", "paged", "contiguous"], default="auto")
    parser.add_argument("--cache-mode", choices=["ssd", "resident"], help="New harness default is SSD; resident is explicit historical reproduction")
    parser.add_argument("--key-mode", choices=["persistent", "ephemeral"], help="SSD default requires persistent KEK; ephemeral is an explicit non-restart test control")
    parser.add_argument("--startup-timeout", type=float, default=180, help="Bound model/hash/key setup before first request (seconds)")
    parser.add_argument("--concurrency", type=int, choices=[1, 2, 4], default=1,
                        help="Copies of each input submitted concurrently; controls actual engine admission")
    grant = parser.add_mutually_exclusive_group()
    grant.add_argument("--kv-budget-gib", type=int, default=None,
                       help="Explicit slot KV grant for envelope tests (default16GiB)")
    grant.add_argument("--production-kv-grant", action="store_true",
                       help="Resolve the single-slot production grant from actual loaded target+assistant weights")
    parser.add_argument("--assistant-directory", help="Exact flat offline assistant artifact; ordinary production verification applies")
    parser.add_argument("--expected-model-sha256", help="Pinned target aggregate SHA-256; requires the candidate production path")
    parser.add_argument("--prompt-date", help="Pin missing request-owned UTC dates as YYYY-MM-DD for paired runs")
    parser.add_argument("--cache-directory", help="Explicit payload root reuse for a separate restart test; default is fresh per invocation")
    parser.add_argument("--trial", type=int, default=1, help="Independent process repetition label; each invocation keeps its own artifact")
    parser.add_argument("--logit-diagnostic-position", type=int,
                        help="Offline observation of one generated index; diagnostic timings are not performance evidence")
    parser.add_argument("--logit-diagnostic-candidates",
                        help="One or two comma-separated token IDs for the selected diagnostic position")
    parser.add_argument("--attention-metadata-position", type=int,
                        help="Graph metadata at one ordinary B1 decode position; no tensor readback")
    parser.add_argument("--attention-packet-position", type=int,
                        help="Native bytes for one ordinary B1 decode position; diagnostic overhead only")
    parser.add_argument("--attention-packet-layer", type=int,
                        help="Storage-owning full-attention layer for the bounded native packet")
    parser.add_argument("--persistent-test-namespace", action="append",
                        help="Owned UUID for an isolated persistent SSD key hierarchy; requires the paired access-group option")
    parser.add_argument("--persistent-test-access-group", action="append",
                        help="Concrete authorized Keychain group for the paired persistent-test namespace")
    args = parser.parse_args(argv)
    if args.kv_budget_gib is None and not args.production_kv_grant:
        args.kv_budget_gib = 16
    if args.key_mode and args.cache_mode != "ssd":
        parser.error("--key-mode requires --cache-mode ssd")
    if args.startup_timeout <= 0:
        parser.error("--startup-timeout must be positive")
    if args.kv_budget_gib is not None and not 1 <= args.kv_budget_gib <= 128:
        parser.error("--kv-budget-gib must be between1 and128")
    if args.trial < 1:
        parser.error("--trial must be positive")
    if args.prompt_date:
        try:
            if date.fromisoformat(args.prompt_date).isoformat() != args.prompt_date:
                raise ValueError()
        except ValueError:
            parser.error("--prompt-date must be a valid YYYY-MM-DD date")
    if args.expected_model_sha256 and (len(args.expected_model_sha256) != 64
            or any(c not in "0123456789abcdef" for c in args.expected_model_sha256)):
        parser.error("--expected-model-sha256 must be 64 lowercase hexadecimal characters")
    if args.production_kv_grant and args.cache_mode == "resident":
        parser.error("--production-kv-grant requires the serving SSD path")
    if args.cache_mode == "resident" and (args.assistant_directory or args.expected_model_sha256):
        parser.error("artifact verification options require the production SSD path")
    if args.gemma_mtp_verification is not None and (
            args.mtp != "on" or args.cache != "off" or args.concurrency != 1
            or not args.production_kv_grant or args.cache_mode != "ssd"
            or args.kv_backend == "auto" or not args.expected_model_sha256):
        parser.error("Gemma verifier control requires B1 MTP-on, cache-off, pinned model, explicit backend and production grant")
    if args.gemma_projection_tokens is not None:
        parts = args.gemma_projection_tokens.split(",")
        if (args.gemma_mtp_verification is None or len(parts) != 2
                or any(not part.isascii() or not part.isdecimal() or str(int(part)) != part
                       or int(part) > 2147483647 for part in parts)
                or args.logit_diagnostic_position is not None or args.logit_diagnostic_candidates is not None
                or args.attention_metadata_position is not None or args.attention_packet_position is not None):
            parser.error("Gemma projection requires two canonical token IDs, an explicit verifier and no other numerical diagnostic")
    if args.logit_diagnostic_position is not None or args.logit_diagnostic_candidates is not None:
        if (args.logit_diagnostic_position is None or args.logit_diagnostic_candidates is None
                or args.concurrency != 1 or args.cache_mode != "ssd"):
            parser.error("diagnostic requires both position and candidates, concurrency1 and explicit SSD mode")
        parts = args.logit_diagnostic_candidates.split(",")
        if (not 0 <= args.logit_diagnostic_position <= 1_000_000
                or not 1 <= len(parts) <= 2
                or any(not part.isascii() or not part.isdecimal() for part in parts)):
            parser.error("invalid diagnostic position or candidate IDs")
        ids = [int(part) for part in parts]
        if len(set(ids)) != len(ids) or any(token > 2_147_483_647 for token in ids):
            parser.error("diagnostic candidate IDs must be distinct nonnegative Int32 values")
        args.logit_diagnostic_candidates = ",".join(map(str, ids))
    if args.attention_metadata_position is not None:
        if (not 1 <= args.attention_metadata_position <= 1_000_000
                or args.concurrency != 1 or args.mtp != "off" or args.cache_mode != "ssd"):
            parser.error("attention metadata requires a positive bounded position, B1, MTP-off and explicit SSD mode")
    if args.attention_packet_position is not None or args.attention_packet_layer is not None:
        if (args.attention_packet_position is None or args.attention_packet_layer is None
                or not 1 <= args.attention_packet_position <= 1_000_000
                or not 0 <= args.attention_packet_layer < 1_024
                or args.concurrency != 1 or args.mtp != "off" or args.cache_mode != "ssd"):
            parser.error("attention packet requires bounded position and layer, B1, MTP-off and explicit SSD mode")
    parse_persistent_test_key_arguments(args, parser)
    return args


def probe_command(args, output):
    command = [args.binary, args.model_directory, args.input,
               str(output), "cache-" + args.cache, "mtp-" + args.mtp, args.kv_backend]
    if args.cache_mode:
        command.append(args.cache_mode)
    if args.key_mode:
        command.append(args.key_mode + "-key")
    # Preserve the historical command line for old immutable B1 artifacts.
    if args.concurrency != 1:
        command.extend(["--concurrency", str(args.concurrency)])
    if args.production_kv_grant:
        command.append("--production-kv-grant")
    elif args.kv_budget_gib != 16:
        command.extend(["--kv-budget-gib", str(args.kv_budget_gib)])
    if args.assistant_directory:
        command.extend(["--assistant-directory", args.assistant_directory])
    if args.expected_model_sha256:
        command.extend(["--expected-model-sha256", args.expected_model_sha256])
    if args.gemma_mtp_verification is not None:
        command.extend(["--gemma-mtp-verification", args.gemma_mtp_verification])
    if args.gemma_projection_tokens is not None:
        command.extend(["--gemma-projection-tokens", args.gemma_projection_tokens])
    if args.logit_diagnostic_position is not None:
        command.extend(["--logit-diagnostic-position", str(args.logit_diagnostic_position),
                        "--logit-diagnostic-candidates", args.logit_diagnostic_candidates])
    if args.attention_metadata_position is not None:
        command.extend(["--attention-metadata-position", str(args.attention_metadata_position)])
    if args.attention_packet_position is not None:
        command.extend(["--attention-packet-position", str(args.attention_packet_position),
                        "--attention-packet-layer", str(args.attention_packet_layer)])
    if args.persistent_test_namespace is not None:
        command.extend(["--persistent-test-namespace", args.persistent_test_namespace,
                        "--persistent-test-access-group", args.persistent_test_access_group])
    return command


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pin_prompt_date(source, destination, day):
    """Keep the real HTTP body, including tools and explicit per-request dates."""
    report = json.loads(Path(source).read_text())
    ids = [row["case"]["id"] for row in report["rows"]]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError("input plan must have nonempty, unique case IDs")
    for row in report["rows"]:
        body = row["request"]
        selected = body.setdefault("_darkbloom_prompt_date", day)
        if not isinstance(selected, str) or date.fromisoformat(selected).isoformat() != selected:
            raise ValueError("invalid explicit request-owned date")
    Path(destination).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")


def mark_aborted_report(path, error):
    """Retain the last atomic checkpoint when the owned process was killed."""
    path = Path(path)
    if not path.exists():
        return
    report = json.loads(path.read_text())
    if report.get("status") not in ("loading", "running"):
        return
    report.update(status="aborted", error=error)
    cells = report.get("rows", []) + report.get("tenant_checks", [])
    cells += [report.get(key, {}) for key in ("warmup", "cancel_donor", "cancelled", "recovered")]
    for row in cells:
        if row.get("outcome") == "running":
            row["outcome"] = "aborted"
    temporary = path.with_suffix(".aborted.tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)



def validate_key_mode(args, report_path):
    if args.persistent_test_namespace is None and (args.cache == "off" or args.cache_mode == "resident"):
        return None
    report = json.loads(Path(report_path).read_text())
    provenance = validate_persistent_test_key_provenance(args, report)
    if args.cache == "off" or args.cache_mode == "resident":
        return provenance
    # Archived serial binaries predate SSD/key-mode reporting. Explicit SSD
    # requests and all current reports must prove the actual key mode.
    if report.get("schema", 1) < 2 and args.cache_mode is None and not args.production_kv_grant:
        return provenance
    expected = "ephemeral" if args.key_mode == "ephemeral" else "persistent"
    actual = report.get("metrics_loaded", {}).get("key_mode")
    if actual != expected:
        raise RuntimeError(f"Requested {expected} cache key, observed {actual!r}")
    return provenance


def main():
    args = arguments()
    key_provenance = persistent_test_key_provenance(args)
    if ranked_job() or subprocess.run(["pgrep", "-x", "darkbloom"], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit("Dedicated host is busy")
    if os.getloadavg()[0] > 4:
        raise SystemExit("Dedicated host load exceeds 4")
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=False)
    macmon = Path.home() / "bench-runner/bin/macmon"
    raw = subprocess.check_output([str(macmon), "pipe", "-s", "1", "-i", "200"], text=True, timeout=10)
    temperature = json.loads(raw.splitlines()[0])["temp"]["gpu_temp_avg"]
    if temperature > 42:
        raise SystemExit(f"GPU entry temperature {temperature} exceeds 42 C")
    metadata = {"started_unix": time.time(), "arguments": dict(vars(args)),
                "entry_gpu_temp_c": temperature, "status": "running",
                "binary_sha256": sha256(args.binary), "source_input_sha256": sha256(args.input)}
    if key_provenance is not None:
        metadata["persistent_test_key_namespace"] = dict(key_provenance, actual_key_mode=None)
    if args.prompt_date:
        prepared = root / "input.json"
        pin_prompt_date(args.input, prepared, args.prompt_date)
        args.input = str(prepared)
    metadata["input_sha256"] = sha256(args.input)
    environment = os.environ.copy()
    # The factory honors the isolated root only with this explicit test opt-in.
    # Persistent mode requires the selected persistent hierarchy: normal when no
    # namespace is supplied, otherwise the explicit test hierarchy, in the SPI and below;
    # an inherited flag must never change an explicitly selected ephemeral cell.
    selected_environment = {
        "DARKBLOOM_PREFIX_CACHE_TEST_ROOT":
            str(Path(args.cache_directory).resolve()) if args.cache_directory else str(root / "prefix-cache"),
        "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
        "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY": "0" if args.key_mode == "ephemeral" else "1",
    }
    environment.update(selected_environment)
    metadata["environment"] = selected_environment
    probe = telemetry = None
    try:
        with (root / "engine.log").open("w") as log, (root / "telemetry.jsonl").open("w") as telemetry_log:
            telemetry = subprocess.Popen([str(macmon), "pipe", "-i", "100"], stdout=telemetry_log,
                                         stderr=subprocess.DEVNULL, start_new_session=True)
            command = probe_command(args, root / "report.json")
            metadata["command"] = command
            probe = subprocess.Popen(command,
                                     env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 1800
            setup_deadline = time.monotonic() + args.startup_timeout
            setup_ready = args.cache_mode == "resident"
            while probe.poll() is None:
                if not setup_ready:
                    setup_ready = "radix-model-ready" in (root / "engine.log").read_text(errors="replace")
                    if not setup_ready and time.monotonic() > setup_deadline:
                        raise RuntimeError("Bounded model/hash/persistent-key setup time exceeded")
                if ranked_job():
                    raise RuntimeError("Ranked job appeared; abandoning owned probe")
                if time.monotonic() > deadline:
                    raise RuntimeError("Bounded benchmark time exceeded")
                time.sleep(1)
            metadata["exit_code"] = probe.returncode
            if probe.returncode:
                raise RuntimeError("Probe failed; inspect engine.log")
        observed_keys = validate_key_mode(args, root / "report.json")
        if observed_keys is not None:
            metadata["persistent_test_key_namespace"] = observed_keys
        metadata["status"] = "completed"
    except BaseException as error:
        metadata["status"] = "failed" if probe is not None and probe.poll() is not None else "aborted"
        metadata["error"] = str(error) or type(error).__name__
        raise
    finally:
        for process in (probe, telemetry):
            terminate(process)
        if metadata["status"] != "completed":
            mark_aborted_report(root / "report.json", metadata.get("error", "owned process stopped"))
        metadata["ended_unix"] = time.time()
        metadata["ranked_job_at_end"] = ranked_job()
        (root / "metadata.json").write_text(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda signum, frame: sys.exit(128 + signum))
    main()
