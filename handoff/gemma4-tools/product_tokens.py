#!/usr/bin/env python3
"""Serve one catalog model through the product's own `darkbloom start --local`
in an isolated home, send greedy chat completions for fixed user texts, record
what came back, and stop the server with SIGTERM (never SIGKILL).

usage: product_tokens.py --binary APP/darkbloom --work DIR --config provider.toml --model ID
                         --port N --out OUT.json --max-tokens N TEXT_FILE [TEXT_FILE...]

Standard library only. The request is the benchmark harness's: temperature 0,
top_p 1, thinking disabled through chat_template_kwargs.
"""
import argparse, http.client, json, os, signal, subprocess, sys, time
from pathlib import Path

parser = argparse.ArgumentParser()
for name in ("--binary", "--work", "--config", "--model", "--out"):
    parser.add_argument(name, required=True)
parser.add_argument("--port", type=int, default=18311)
parser.add_argument("--max-tokens", type=int, action="append", required=True)
parser.add_argument("--start-seconds", type=float, default=600)
parser.add_argument("texts", nargs="+")
a = parser.parse_args()
work = Path(a.work).resolve(); run = work / "run"
for folder in (work / "home", work / "tmp", run, work / "local", work / "prefix-cache"):
    folder.mkdir(parents=True, exist_ok=True)
env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(work / "home"), "CFFIXED_USER_HOME": str(work / "home"),
       "TMPDIR": str(work / "tmp"), "DARKBLOOM_PID_FILE": str(run / "provider.pid"),
       "DARKBLOOM_STATE_FILE": str(run / "daemon-state.json"), "DARKBLOOM_LOCAL_DIR": str(work / "local"),
       "DARKBLOOM_LOADED_MODELS_FILE": str(run / "loaded-models.json"),
       "DARKBLOOM_WATCHDOG_STATE": str(run / "watchdog-state.json"),
       "DARKBLOOM_AUTH_TOKEN_PATH": str(run / "auth_token"),
       "DARKBLOOM_KV_BACKEND_GUARD": str(run / "kv-backend-guard.json"), "DARKBLOOM_NO_UPDATE_CHECK": "1",
       "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1", "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": str(work / "prefix-cache")}
command = [a.binary, "start", "--local", "--model", a.model, "--port", str(a.port), "--bind", "127.0.0.1",
           "--config", a.config]
log = open(str(Path(a.out).with_suffix(".server.log")), "w")
server = subprocess.Popen(command, env=env, cwd=str(work), stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
results = {"model": a.model, "requests": [], "server_exit": None}
try:
    deadline = time.time() + a.start_seconds; ready = False
    while time.time() < deadline and server.poll() is None:
        try:
            c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=2); c.request("GET", "/health")
            ready = c.getresponse().status == 200; c.close()
        except OSError:
            ready = False
        if ready: break
        time.sleep(0.5)
    if not ready: raise SystemExit("server did not become ready")
    limits = a.max_tokens + [a.max_tokens[-1]] * (len(a.texts) - len(a.max_tokens))
    for path, limit in zip(a.texts, limits):
        text = Path(path).read_text()
        body = {"model": a.model, "messages": [{"role": "user", "content": text}], "max_tokens": limit,
                "temperature": 0, "top_p": 1, "stream": True, "stream_options": {"include_usage": True},
                "chat_template_kwargs": {"enable_thinking": False}}
        began = time.time()
        c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=900)
        c.request("POST", "/v1/chat/completions", json.dumps(body), {"Content-Type": "application/json", "Accept": "text/event-stream"})
        r = c.getresponse(); pieces = []; reasoning = []; usage = None; finish = None; first = None; raw_error = None
        if r.status != 200: raw_error = r.read().decode("utf-8", "replace")[:2000]
        else:
            for line in r:
                line = line.decode("utf-8", "replace").strip()
                if not line.startswith("data:"): continue
                data = line[5:].strip()
                if data == "[DONE]": break
                event = json.loads(data)
                if event.get("usage"): usage = event["usage"]
                for choice in event.get("choices", []):
                    delta = choice.get("delta", {})
                    if delta.get("content"):
                        if first is None: first = time.time() - began
                        pieces.append(delta["content"])
                    if delta.get("reasoning_content") or delta.get("reasoning"):
                        reasoning.append(delta.get("reasoning_content") or delta.get("reasoning"))
                    if choice.get("finish_reason"): finish = choice["finish_reason"]
        c.close()
        results["requests"].append({"text_file": os.path.basename(path), "max_tokens": limit, "http_status": r.status,
            "error": raw_error, "content": "".join(pieces), "reasoning": "".join(reasoning), "usage": usage,
            "finish_reason": finish, "first_content_seconds": first, "total_seconds": time.time() - began})
        print(os.path.basename(path), r.status, usage, finish, flush=True)
    try:
        c = http.client.HTTPConnection("127.0.0.1", a.port, timeout=10); c.request("GET", "/metrics")
        metrics = c.getresponse().read().decode("utf-8", "replace"); c.close()
        results["metrics"] = [line for line in metrics.splitlines()
                              if not line.startswith("#") and any(k in line for k in ("kv_backend", "mtp", "backend_info"))][:40]
    except OSError as error:
        results["metrics"] = ["unavailable: %s" % error]
finally:
    if server.poll() is None:
        server.send_signal(signal.SIGTERM)
        while True:
            try:
                server.wait(timeout=60); break
            except subprocess.TimeoutExpired:
                print("server still running after SIGTERM; waiting (never SIGKILL)", flush=True)
    results["server_exit"] = server.returncode
    Path(a.out).write_text(json.dumps(results, indent=1, sort_keys=True))
