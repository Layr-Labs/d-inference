#!/usr/bin/env python3
"""Drive admission, refusal, cancellation, concurrency and drain on the Super runner
while sampling memory, and compare measured peaks with the reservations held.

Run with ``python3 -I``; see memory_calibration.md for the procedure and fields.

  python3 -I memory_calibration.py --out C.json --launch-runner BIN --runner-arg=--checkpoint --runner-arg=DIR
  python3 -I memory_calibration.py --out C.json --runner-state STATE_DIR   (no drain/restart scenario)
"""
import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import signal
import sys
import threading
import time

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # never write a cache into the source checkout
_spec = importlib.util.spec_from_file_location("super_runner_client", HERE / "super_runner_client.py")
client = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(client)

SCHEMA = "nemotron-super-memory-calibration/1"
MIB = 1 << 20
REQUEST_KINDS = ("media_ingress", "media", "kv", "prefill_lane")


class Calibration:
    def __init__(self, runner, args):
        self.runner = runner
        self.args = args
        self.seed = args.seed
        self.nonce = 0
        self.invariants = []
        self.baseline = None

    # Workloads ---------------------------------------------------------------
    def text_body(self, tokens, max_tokens=None):
        self.nonce += 1
        text = client.prompt_text(max(1, int(tokens * self.args.words_per_token)), self.seed,
                                  f"cal-{self.seed:x}-{self.nonce:06d}")
        return client.chat_body(text, max_tokens or self.args.max_tokens, self.seed, thinking=False)

    def image_body(self, width, height, max_tokens=None):
        self.nonce += 1
        return client.chat_body(f"cal-{self.nonce:06d}. Describe the image.", max_tokens or self.args.max_tokens,
                                self.seed, image_png=client.png_rgb(width, height, self.seed), thinking=False)

    def workloads(self):
        result = [(f"text.{name}", lambda tokens=tokens: self.text_body(tokens))
                  for name, tokens in client.parse_contexts(self.args.contexts).items()]
        result += [(f"image.{w}x{h}", lambda w=w, h=h: self.image_body(w, h))
                   for w, h in client.parse_images(self.args.images)]
        return result

    def record(self, name, result, evidence):
        self.invariants.append({"name": name, "result": result, "evidence": evidence})

    # Ledger observation -----------------------------------------------------
    def settled(self, timeout=120.0):
        """Wait until no request or ballast charge remains and HTTP/bridge work is idle.

        ``leak`` compares the whole ledger with the idle baseline: ``none`` when it
        is equal, ``review`` when only unattributed (engine-owner) charge moved,
        ``request_charge`` when a request reservation never retired.
        """
        start = time.perf_counter()
        while True:
            snapshot = self.runner.memory()
            context = snapshot["context"]
            held = [row for row in snapshot["charges"]["rows"] if row["kind"] != "load"]
            idle = (not held and context["bridge_active_requests"] == 0
                    and context["http_active_responses"] == 0)
            if idle or time.perf_counter() - start > timeout:
                charged, baseline = snapshot["ledger"]["charged"], self.baseline["ledger"]["charged"]
                leak = "request_charge" if held else "none" if charged == baseline else "review"
                return {"settled": idle, "leak": leak, "after_s": time.perf_counter() - start,
                        "charged": charged, "baseline_charged": baseline,
                        "owners": snapshot["ledger"]["owners"], "baseline_owners": self.baseline["ledger"]["owners"],
                        "unattributed_bytes": snapshot["charges"].get("unattributed_bytes"),
                        "baseline_unattributed_bytes": self.baseline["charges"].get("unattributed_bytes")}
            time.sleep(0.005)

    def geometry(self, name, make_body):
        """Request reservations versus measured transient peaks at concurrency 1."""
        self.runner.reset_peaks()
        before = self.runner.memory()
        sample = self.runner.chat(make_body(), timeout=self.args.request_timeout)
        after = self.runner.memory()
        window = after["window"]
        reserved = window["sampled_max_charge_by_kind"]
        request_bytes = window["sampled_max_request_charges_held"]
        active_before = before["memory"]["mlx_active"]
        mlx_delta = window["mlx_peak"] - active_before
        footprint_delta = (window["kernel_max_phys_footprint"] or window["sampled_max_phys_footprint"]) \
            - before["memory"]["phys_footprint"]
        reserve = after["ledger"]["activation_reserve"]
        row = {"workload": name, "status": sample["status"], "error": sample.get("error"),
               "prompt_tokens": sample.get("prompt_tokens"), "completion_tokens": sample.get("completion_tokens"),
               "reserved_by_kind_sampled_max": reserved, "request_reserved_bytes": request_bytes,
               "request_reserved_bytes_definition":
                   "max over samples of media_ingress+media+kv+prefill_lane held at once",
               "activation_reserve_bytes": reserve,
               "measured_mlx_peak_delta_bytes": mlx_delta,
               "measured_phys_footprint_delta_bytes": footprint_delta,
               "margin_vs_request_reservations_bytes": request_bytes - mlx_delta,
               "margin_vs_request_plus_activation_reserve_bytes": request_bytes + reserve - mlx_delta,
               "window": window, "settle": self.settled()}
        observed = request_bytes > 0
        ok = sample["status"] == 200 and not sample.get("error")
        if not ok:
            verdict = "fail"
        elif not observed:
            verdict = "not_observed"
        else:
            verdict = "pass" if request_bytes + reserve >= mlx_delta else "fail"
        self.record(f"reservation_covers_peak.{name}", verdict, {
            "request_reserved_bytes": request_bytes, "activation_reserve_bytes": reserve,
            "measured_mlx_peak_delta_bytes": mlx_delta,
            "note": "sampled charges only; raise runner --sample-interval-ms resolution if not_observed"})
        self.record(f"no_leak_after_success.{name}", leak_verdict(row["settle"]), row["settle"])
        return row

    def near_limit(self, name, make_body, reference_bytes):
        """Ballast leaves just below / just above the reference reservation."""
        margin = int(self.args.near_limit_margin_mib * MIB)
        if reference_bytes <= margin:
            self.record(f"near_limit_boundary.{name}", "not_exercised",
                        {"reference_request_bytes": reference_bytes, "margin_bytes": margin,
                         "reason": "reference reservation is not larger than the margin"})
            return {"workload": name, "margin_bytes": margin, "rows": []}
        rows = []
        for side, offset in (("refuse", margin), ("admit", -margin)):
            remaining = self.runner.memory()["ledger"]["remaining"]
            ballast = max(0, remaining - reference_bytes + offset)
            ballast_result = self.runner.set_ballast(ballast)
            if not ballast_result.get("accepted"):
                rows.append({"side": side, "ballast": ballast_result, "admitted": None})
                continue
            after_ballast = self.runner.memory()
            self.runner.reset_peaks()
            sample = self.runner.chat(make_body(), timeout=self.args.request_timeout)
            window = self.runner.memory()["window"]
            self.runner.set_ballast(0)
            settle = self.settled()
            admitted = sample["status"] == 200 and not sample.get("error")
            rows.append({"side": side, "remaining_before_ballast": remaining, "ballast": ballast_result,
                         "remaining_after_ballast": after_ballast["ledger"]["remaining"],
                         "reference_request_bytes": reference_bytes, "status": sample["status"],
                         "error": sample.get("error"), "admitted": admitted,
                         "reserved_by_kind_sampled_max": window["sampled_max_charge_by_kind"],
                         "mlx_peak_delta_bytes": window["mlx_peak"] - after_ballast["memory"]["mlx_active"],
                         "settle": settle})
        if any(row["admitted"] is None for row in rows):
            verdict = "not_exercised"  # the ballast itself was refused
        else:
            verdict = "pass" if (not rows[0]["admitted"]) and rows[1]["admitted"] else "inconsistent"
        self.record(f"near_limit_boundary.{name}", verdict, {
            "margin_bytes": margin, "reference_request_bytes": reference_bytes,
            "sides": [{k: r.get(k) for k in ("side", "admitted", "status", "error", "remaining_after_ballast")}
                      for r in rows]})
        return {"workload": name, "margin_bytes": margin, "rows": rows}

    def cancel(self, name, make_body, phase):
        """Disconnect when ``phase`` is observed, then follow retirement of every charge."""
        abort = client.AbortHandle()
        first = threading.Event()
        holder = {}

        def on_first():
            first.set()
            if phase == "decode":
                abort.abort()

        thread = threading.Thread(target=lambda: holder.update(self.runner.chat(
            make_body(), timeout=self.args.request_timeout, abort=abort, on_first_delta=on_first)))
        thread.start()
        observed = None
        at_abort = None
        deadline = time.perf_counter() + self.args.request_timeout
        while thread.is_alive() and time.perf_counter() < deadline and observed is None:
            snapshot = self.runner.memory()
            kinds = {row["kind"] for row in snapshot["charges"]["rows"]}
            current = current_phase(kinds, first.is_set())
            if phase == "decode" and abort.aborted_at is not None:
                observed, at_abort = "decode", snapshot
            elif current == phase:
                abort.abort()
                observed, at_abort = current, snapshot
            else:
                time.sleep(0.002)
        if observed is None and phase == "decode" and abort.aborted_at is not None:
            # on_first_delta aborted on the request thread, which may end first.
            observed, at_abort = "decode", self.runner.memory()
        timeline = []
        start = time.perf_counter()
        charge_gone = bridge_idle = http_idle = None
        while time.perf_counter() - start < 120:
            snapshot = self.runner.memory()
            request_rows = [r for r in snapshot["charges"]["rows"] if r["kind"] in REQUEST_KINDS]
            context = snapshot["context"]
            now = time.perf_counter() - start
            timeline.append({"t_s": now, "request_charges": len(request_rows),
                             "bridge_active": context["bridge_active_requests"],
                             "http_active": context["http_active_responses"]})
            if charge_gone is None and not request_rows:
                charge_gone = now
            if bridge_idle is None and context["bridge_active_requests"] == 0:
                bridge_idle = now
            if http_idle is None and context["http_active_responses"] == 0:
                http_idle = now
            if charge_gone is not None and bridge_idle is not None and http_idle is not None:
                break
            time.sleep(0.005)
        thread.join(timeout=self.args.request_timeout)
        settle = self.settled()
        # A charge refunded while the bridge still reports the request active is
        # an early refund; one sample interval of slack separates the two reads.
        # Before bridge submission (ingress/media) the HTTP response lease is the
        # only outside view of live work, so its idle time is recorded too.
        early = charge_gone is not None and bridge_idle is not None and charge_gone + 0.02 < bridge_idle
        verdict = ("not_observed" if observed is None else
                   "fail" if early or not settle["settled"] else leak_verdict(settle))
        self.record(f"cancellation.{name}.{phase}", verdict, {
            "observed_phase": observed, "early_refund": early, "charge_gone_s": charge_gone,
            "bridge_idle_s": bridge_idle, "http_idle_s": http_idle, "settled": settle["settled"]})
        return {"workload": name, "target_phase": phase, "observed_phase": observed,
                "charges_at_abort": at_abort and at_abort["charges"], "request": holder,
                "timeline": timeline[:400], "settle": settle}

    def concurrency(self, level, make_body):
        snapshots = []
        stop = threading.Event()

        def poll():
            while not stop.is_set():
                snapshots.append(self.runner.memory())
                time.sleep(0.02)

        results = [None] * level
        barrier = threading.Barrier(level)

        def worker(index):
            barrier.wait()
            results[index] = self.runner.chat(make_body(), timeout=self.args.request_timeout)

        bodies_ready = [threading.Thread(target=worker, args=(i,)) for i in range(level)]
        self.runner.reset_peaks()
        poller = threading.Thread(target=poll)
        poller.start()
        for thread in bodies_ready:
            thread.start()
        for thread in bodies_ready:
            thread.join()
        stop.set()
        poller.join()
        window = self.runner.memory()["window"]
        cap = snapshots[0]["ledger"]["cap"] if snapshots else None
        max_charged = max((s["ledger"]["charged"] for s in snapshots), default=None)
        statuses = {}
        for result in results:
            key = str(result["status"]) + (" error" if result.get("error") else "")
            statuses[key] = statuses.get(key, 0) + 1
        settle = self.settled()
        within = cap is None or max_charged is None or max_charged <= cap
        self.record(f"concurrency.{level}.within_cap_and_settled",
                    leak_verdict(settle) if within else "fail",
                    {"cap": cap, "polled_max_charged": max_charged, "statuses": statuses, "settled": settle["settled"]})
        return {"concurrency": level, "statuses": statuses, "polled_samples": len(snapshots),
                "polled_max_charged": max_charged, "polled_max_by_kind": max_by_kind(snapshots),
                "window": window, "requests": results, "settle": settle}

    def drain_and_restart(self, make_body):
        """SIGTERM during decode, then a fresh restart; requires a launched runner."""
        first = threading.Event()
        holder = {}
        thread = threading.Thread(target=lambda: holder.update(self.runner.chat(
            make_body(), timeout=self.args.request_timeout, on_first_delta=first.set)))
        thread.start()
        first.wait(timeout=self.args.request_timeout)
        code = self.runner.stop(signal.SIGTERM, timeout=self.args.drain_timeout)
        thread.join(timeout=60)
        retirement = (self.runner.events("retirement") or [None])[-1]
        drained = (self.runner.events("shutdown.drained") or [None])[-1]
        clean = code == 0 and bool(retirement and retirement.get("clean"))
        self.record("drain.sigterm_during_decode", "pass" if clean else "fail",
                    {"exit_code": code, "retirement_clean": retirement and retirement.get("clean"),
                     "request_status": holder.get("status"), "request_error": holder.get("error")})
        restarted = client.Runner.launch_process(self.runner.launch["command"], self.args.work_dir_resolved,
                                                 timeout=self.args.ready_timeout)
        try:
            sample = restarted.chat(self.text_body(32, max_tokens=4), timeout=self.args.request_timeout)
        finally:
            restart_code = restarted.stop(signal.SIGINT)
        restart_retirement = (restarted.events("retirement") or [None])[-1]
        restart_clean = restart_code == 0 and sample["status"] == 200 and bool(
            restart_retirement and restart_retirement.get("clean"))
        self.record("restart.serve_and_clean_exit", "pass" if restart_clean else "fail",
                    {"exit_code": restart_code, "status": sample["status"],
                     "ready_s": restarted.launch.get("process_start_to_ready_s")})
        return {"sigterm": {"exit_code": code, "request": holder, "shutdown_drained": drained,
                            "retirement": retirement},
                "restart": {"launch": restarted.launch, "request": sample, "exit_code": restart_code,
                            "retirement": restart_retirement}}


def leak_verdict(settle):
    if not settle["settled"] or settle["leak"] == "request_charge":
        return "fail"
    return "pass" if settle["leak"] == "none" else "review"


def current_phase(kinds, streamed):
    if streamed:
        return "decode"
    if "kv" in kinds:
        return "prefill"
    if "media" in kinds:
        return "media"
    if "media_ingress" in kinds:
        return "ingress"
    return None


def max_by_kind(snapshots):
    result = {}
    for snapshot in snapshots:
        for kind, value in snapshot["charges"]["by_kind"].items():
            result[kind] = max(result.get(kind, 0), value)
    return result


def load_comparison(runner):
    begin = (runner.events("load.begin") or [{}])[-1]
    end = (runner.events("load.end") or [{}])[-1]
    quote = (runner.events("load.quote") or [{}])[-1]
    window = end.get("load_window", {}).get("closed_window", {})
    footprint_peak = window.get("kernel_max_phys_footprint") or window.get("sampled_max_phys_footprint")
    footprint_before = (begin.get("memory") or {}).get("phys_footprint")
    claim = quote.get("pending_load_claim_bytes")
    delta = footprint_peak - footprint_before if footprint_peak and footprint_before is not None else None
    return {"load_quote_bytes": quote.get("load_quote_bytes"), "pending_load_claim_bytes": claim,
            "sampled_max_load_charge_bytes": (window.get("sampled_max_charge_by_kind") or {}).get("load"),
            "kernel_max_phys_footprint_bytes": footprint_peak, "phys_footprint_at_load_begin_bytes": footprint_before,
            "measured_footprint_delta_bytes": delta, "mlx_peak_during_load_bytes": window.get("mlx_peak"),
            "margin_bytes": claim - delta if claim is not None and delta is not None else None,
            "load_seconds": end.get("seconds"), "phases": end.get("phases")}


def run(args):
    work = Path(args.work_dir or Path(args.out).with_suffix(".work")).resolve()
    args.work_dir_resolved = work
    if args.launch_runner:
        runner = client.Runner.launch_process([args.launch_runner] + args.runner_arg, work, timeout=args.ready_timeout)
    else:
        runner = client.Runner(args.runner_state)
    calibration = Calibration(runner, args)
    receipt = {"schema": SCHEMA, "created": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "claim_scope": client.claim_scope(runner),
               "settings": {k: v for k, v in vars(args).items() if k != "work_dir_resolved"}}
    receipt.update(client.provenance(runner, args.source, args.model_dir))
    stopped = False
    try:
        calibration.baseline = runner.memory()
        receipt["idle_baseline"] = calibration.baseline
        receipt["load"] = load_comparison(runner)
        load = receipt["load"]
        calibration.record("load_claim_covers_measured_load_footprint",
                           "not_observed" if load["margin_bytes"] is None else
                           "pass" if load["margin_bytes"] >= 0 else "fail",
                           {k: load[k] for k in ("pending_load_claim_bytes", "measured_footprint_delta_bytes",
                                                 "margin_bytes")})
        workloads = calibration.workloads()
        receipt["geometry"] = [calibration.geometry(name, make) for name, make in workloads]
        reference = next((row for row in receipt["geometry"]
                          if row["workload"].startswith("image.") and row["request_reserved_bytes"] > 0),
                         next((row for row in receipt["geometry"] if row["request_reserved_bytes"] > 0), None))
        if reference is not None:
            make = dict(workloads)[reference["workload"]]
            receipt["near_limit"] = calibration.near_limit(reference["workload"], make,
                                                           reference["request_reserved_bytes"])
        else:
            calibration.record("near_limit_boundary", "not_exercised", "no request reservation was observed")
        receipt["cancellation"] = []
        images = client.parse_images(args.images)
        contexts = client.parse_contexts(args.contexts)
        if images:
            w, h = max(images, key=lambda size: size[0] * size[1])
            for phase in ("ingress", "media", "prefill", "decode"):
                receipt["cancellation"].append(calibration.cancel(
                    f"image.{w}x{h}", lambda: calibration.image_body(w, h, args.cancel_max_tokens), phase))
        if contexts:
            name, tokens = max(contexts.items(), key=lambda item: item[1])
            for phase in ("prefill", "decode"):
                receipt["cancellation"].append(calibration.cancel(
                    f"text.{name}", lambda: calibration.text_body(tokens, args.cancel_max_tokens), phase))
        middle = sorted(contexts.values())[len(contexts) // 2] if contexts else 128
        receipt["concurrency"] = [calibration.concurrency(int(level), lambda: calibration.text_body(middle))
                                  for level in args.concurrency.split(",") if level]
        calibration.record("native_completion_failure", "not_exercised",
                           "needs a fault-injection seam in the bridge; not available to an HTTP client")
        if runner.process is not None and not args.skip_drain:
            receipt["drain_restart"] = calibration.drain_and_restart(
                lambda: calibration.text_body(middle, args.cancel_max_tokens))
            stopped = True
    finally:
        receipt["invariants"] = calibration.invariants
        Path(args.out).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        if runner.process is not None and not stopped:
            try:
                code = runner.stop()
                receipt["runner_exit"] = {"code": code,
                                          "retirement": (runner.events("retirement") or [None])[-1]}
            except client.RunnerError as error:
                receipt["runner_exit"] = {"code": None, "error": str(error)}
            Path(args.out).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    counts = {}
    for invariant in calibration.invariants:
        counts[invariant["result"]] = counts.get(invariant["result"], 0) + 1
    print(json.dumps({"claim_scope": receipt["claim_scope"], "invariants": counts,
                      "failures": [i["name"] for i in calibration.invariants if i["result"] == "fail"]}, indent=2))
    return 0 if "fail" not in counts else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--launch-runner")
    target.add_argument("--runner-state")
    parser.add_argument("--runner-arg", action="append", default=[])
    parser.add_argument("--work-dir")
    parser.add_argument("--ready-timeout", type=float, default=3600)
    parser.add_argument("--contexts", default="short=128,medium=2048,long=15360")
    parser.add_argument("--images", default="512x512,1024x1024,2048x1536")
    parser.add_argument("--concurrency", default="2,4,8")
    parser.add_argument("--max-tokens", type=int, default=32)
    parser.add_argument("--cancel-max-tokens", type=int, default=512)
    parser.add_argument("--words-per-token", type=float, default=0.75)
    parser.add_argument("--near-limit-margin-mib", type=float, default=8)
    parser.add_argument("--seed", type=int, default=1234)
    parser.add_argument("--request-timeout", type=float, default=1800)
    parser.add_argument("--drain-timeout", type=float, default=900)
    parser.add_argument("--skip-drain", action="store_true")
    parser.add_argument("--source", action="append", default=[])
    parser.add_argument("--model-dir")
    args = parser.parse_args()
    client.exit_on_sigterm()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
