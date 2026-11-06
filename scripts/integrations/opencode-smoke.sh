#!/usr/bin/env bash
#
# Smoke test of Darkbloom's OpenCode config writer against the real OpenCode 2.
#
# The real writer (the opt-in `OpenCodeSmokeSetup` test, run through `swift test`) reads a live endpoint from
# local.json, asks a fake OpenAI-compatible server for its models with the key from the key file, and writes
# OpenCode's config. Then the real OpenCode lists the models, shows the config and runs one prompt against the fake
# server, which records what it was sent.
#
# Nothing real is read or written: HOME, every XDG_* folder, TMPDIR and Darkbloom's discovery folder
# (DARKBLOOM_LOCAL_DIR) are inside one temp folder; OpenCode runs under `env -i` with `--standalone` (its own private server, never the
# background service) and OPENCODE_DISABLE_PROJECT_CONFIG=1. The fake server listens on 127.0.0.1 on a port the
# system picks; the key is a fake one made for the run.
#
# Usage: scripts/integrations/opencode-smoke.sh [--skip-build] [--scratch-path DIR] [--opencode PATH] [--keep]
#   --skip-build      use the existing test build (swift test --skip-build)
#   --scratch-path    SwiftPM's build folder (default: provider-swift/.build)
#   --opencode        the OpenCode binary (default: opencode on PATH, else ~/.opencode/bin/opencode)
#   --keep            keep the temp folder for inspection
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
skip_build=()
scratch=()
opencode=""
keep=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) skip_build=(--skip-build); shift ;;
        --scratch-path) scratch=(--scratch-path "$2"); shift 2 ;;
        --opencode) opencode="$2"; shift 2 ;;
        --keep) keep=1; shift ;;
        *) echo "usage: $0 [--skip-build] [--scratch-path DIR] [--opencode PATH] [--keep]" >&2; exit 2 ;;
    esac
done
if [[ -z "$opencode" ]]; then
    opencode="$(command -v opencode || true)"
    [[ -n "$opencode" ]] || opencode="$HOME/.opencode/bin/opencode"
fi
[[ -x "$opencode" ]] || { echo "OpenCode isn't installed ($opencode)" >&2; exit 2; }

work="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/opencode-smoke.XXXXXX")" && pwd -P)"
server_pid=""
cleanup() {
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
    if [[ $keep == 1 ]]; then echo "kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

failures=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

token="$(python3 -c 'import secrets; print("dk-local-" + secrets.token_urlsafe(32))')"
printf '%s' "$token" > "$work/server-token"

# The fake server: GET /v1/models and POST /v1/chat/completions (streamed or not), both behind the bearer key.
# Its log records whether the bearer matched, never the key itself.
cat > "$work/fake_server.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

token = open(sys.argv[1]).read().strip()
log = open(sys.argv[2], "a")
models = json.loads(sys.argv[4])

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def record(self, body=None):
        entry = {"method": self.command, "path": self.path,
                 "auth_ok": self.headers.get("Authorization", "") == "Bearer " + token,
                 "route_header": self.headers.get("X-Darkbloom-Route")}
        if isinstance(body, dict):
            entry.update(keys=sorted(body), model=body.get("model"), stream=body.get("stream"),
                         max_tokens=body.get("max_tokens"))
        log.write(json.dumps(entry) + "\n")
        log.flush()
        return entry["auth_ok"]

    def reply(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.record():
            return self.reply(401, {"error": {"message": "invalid key"}})
        if self.path.rstrip("/") != "/v1/models":
            return self.reply(404, {"error": {"message": "not found"}})
        self.reply(200, {"object": "list", "data": [
            {"id": m["id"], "object": "model", "owned_by": "local",
             "context_length": m["context"], "max_model_len": m["context"]} for m in models]})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if not self.record(body):
            return self.reply(401, {"error": {"message": "invalid key"}})
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self.reply(404, {"error": {"message": "not found"}})
        base = {"id": "smoke", "created": int(time.time()), "model": body.get("model")}
        if not body.get("stream"):
            return self.reply(200, {**base, "object": "chat.completion", "choices": [
                {"index": 0, "message": {"role": "assistant", "content": "OK"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 6}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for chunk in ({"choices": [{"index": 0, "delta": {"role": "assistant", "content": "OK"}, "finish_reason": None}]},
                      {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                       "usage": {"prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 6}}):
            self.wfile.write(("data: " + json.dumps({**base, "object": "chat.completion.chunk", **chunk}) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[3], "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
PY

models='[{"id": "qwen3.8-27b", "context": 131072}, {"id": "mlx-community/gemma-4-26b-qat-4bit", "context": 65536}]'
python3 "$work/fake_server.py" "$work/server-token" "$work/requests.log" "$work/port" "$models" &
server_pid=$!
for _ in $(seq 1 100); do [[ -s "$work/port" ]] && break; sleep 0.1; done
port="$(cat "$work/port")"
case "$port" in 8000|47420|47421|47422|47423) echo "the system gave a reserved port ($port)" >&2; exit 1 ;; esac
echo "fake server: 127.0.0.1:$port (pid $server_pid); OpenCode: $("$opencode" --version 2>/dev/null | head -1)"

# A throwaway home with Darkbloom's discovery folder: the key file and a local.json naming the fake server.
prepare_home() {
    local home="$1"
    mkdir -p "$home/.darkbloom" "$home/.config" "$home/.local/share" "$home/.local/state" "$home/.cache" "$home/.tmp"
    (umask 077 && printf '%s' "$token" > "$home/.darkbloom/local_token")
    python3 - "$home/.darkbloom/local.json" "$port" "$server_pid" "$token" <<'PY'
import json, sys
path, port, pid, key = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
json.dump({"base_url": f"http://127.0.0.1:{port}/v1", "api_key": key, "host": "127.0.0.1", "port": port,
           "pid": pid, "version": "smoke", "updated_at": "2026-11-06T00:00:00Z"}, open(path, "w"), indent=2)
PY
    chmod 600 "$home/.darkbloom/local.json"
}

# The real writer, through the opt-in test, at nice 19.
write_config() {
    local home="$1" log="$2"
    DARKBLOOM_OPENCODE_SMOKE_HOME="$home" DARKBLOOM_LOCAL_DIR="$home/.darkbloom" \
        nice -n 19 swift test --package-path "$repo/provider-swift" ${scratch[@]+"${scratch[@]}"} \
        ${skip_build[@]+"${skip_build[@]}"} --filter OpenCodeSmokeSetup > "$log" 2>&1
}

result() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$1/smoke-result.json" "$2"; }

# OpenCode in the throwaway home: no inherited environment, no project config, 120 s at most. Every command that
# talks to a server gets `--standalone` (its own private server, never the background service).
run_opencode() {
    local home="$1"; shift
    (cd "$work/project" && perl -e 'alarm shift; exec @ARGV' 120 env -i PATH=/usr/bin:/bin HOME="$home" \
        XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" XDG_STATE_HOME="$home/.local/state" \
        XDG_CACHE_HOME="$home/.cache" TMPDIR="$home/.tmp" OPENCODE_DISABLE_PROJECT_CONFIG=1 \
        OPENCODE_DISABLE_AUTOUPDATE=1 TERM=dumb "$opencode" "$@")
}
mkdir -p "$work/project"

# 1. A new config.
home="$work/home"
prepare_home "$home"
if ! write_config "$home" "$work/writer-1.log"; then
    tail -40 "$work/writer-1.log"
    fail "the writer ran"
    exit 1
fi
provider="$(result "$home" provider)"
config="$(result "$home" file)"
check "the writer wrote $config (outcome: $(result "$home" outcome))" [ "$(result "$home" outcome)" = written ]
check "the config is in the throwaway home" [ "${config#"$home/"}" != "$config" ]
check "the endpoint is the live one from local.json (port $port)" \
    [ "$(result "$home" base_url)" = "http://127.0.0.1:$port/v1" ]
check "the key is referenced by its file, not written" grep -q '"apiKey": "{file:~/.darkbloom/local_token}"' "$config"
check "max_tokens is the output-cap field" grep -q '"maxTokensField": "max_tokens"' "$config"
check "the default model was set (the file had none)" grep -q "\"model\": \"$provider/" "$config"
write_config "$home" "$work/writer-2.log" || true
check "a second run changes nothing" [ "$(result "$home" outcome)" = unchanged ]

run_opencode "$home" debug paths > "$work/paths.txt" 2>&1 || true
check "OpenCode's own paths are all in the throwaway home" \
    python3 -c 'import sys; lines=[l for l in open(sys.argv[1]) if "/" in l]; sys.exit(0 if lines and all(sys.argv[2] in l for l in lines) else 1)' \
    "$work/paths.txt" "$work"

run_opencode "$home" models --standalone > "$work/models.txt" 2>&1 || true
check "opencode models lists $provider/qwen3.8-27b" grep -q "^$provider/qwen3.8-27b\$" "$work/models.txt"
check "opencode models lists $provider/mlx-community/gemma-4-26b-qat-4bit" \
    grep -q "^$provider/mlx-community/gemma-4-26b-qat-4bit\$" "$work/models.txt"

run_opencode "$home" debug config --standalone > "$work/debug-config.txt" 2>&1 || true
check "opencode debug config shows the provider" grep -q "\"$provider\"" "$work/debug-config.txt"
check "opencode debug config hides the key" grep -q '\*\*\*' "$work/debug-config.txt"
check "opencode debug config never prints the key" bash -c '! grep -qF "$1" "$2"' _ "$token" "$work/debug-config.txt"

: > "$work/requests.log"
run_opencode "$home" run --standalone -m "$provider/qwen3.8-27b" "Reply with OK" > "$work/run.txt" 2>&1 || true
check "opencode run answers OK" grep -q "OK" "$work/run.txt"
check "the fake server got chat requests" grep -q '"path": "/v1/chat/completions"' "$work/requests.log"
check "every request carried the key file's key" \
    python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; sys.exit(0 if r and all(x["auth_ok"] for x in r) else 1)' "$work/requests.log"
# OpenCode's agent turn (the request with tools) sends the model's output limit; its short title request sends no
# cap at all. Neither may use max_completion_tokens, which the engine ignores.
check "the agent turn sends max_tokens = limit.output (32768); nothing sends max_completion_tokens" \
    python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1]) if "chat" in l]; turns=[x for x in r if "tools" in x["keys"]]; sys.exit(0 if turns and all(x["max_tokens"] == 32768 for x in turns) and not any("max_completion_tokens" in x["keys"] for x in r) else 1)' "$work/requests.log"
check "no request carried X-Darkbloom-Route" \
    python3 -c 'import json,sys; sys.exit(0 if all(json.loads(l)["route_header"] is None for l in open(sys.argv[1])) else 1)' "$work/requests.log"
run_opencode "$home" run --standalone -m "$provider/mlx-community/gemma-4-26b-qat-4bit" "Reply with OK" > "$work/run-slash.txt" 2>&1 || true
check "a model ID with a slash runs too" grep -q "OK" "$work/run-slash.txt"
check "its agent turn sends its own limit.output (16384)" \
    python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1]) if "gemma" in l and "tools" in l]; sys.exit(0 if r and all(x["max_tokens"] == 16384 for x in r) else 1)' "$work/requests.log"
check "OpenCode's log has no configuration diagnostic" \
    bash -c '! grep -rqiE "normalization diagnostic|configuration is invalid" "$1"' _ "$home/.local/share/opencode/log"

# 2. An owner's opencode.json with a V1 oMLX block and a default model: both stay, Darkbloom's provider is added.
home="$work/home-owner"
prepare_home "$home"
mkdir -p "$home/.config/opencode"
cat > "$home/.config/opencode/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "omlx/Qwen3.6-35B-A3B-4bit",
  "provider": {
    "omlx": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "oMLX",
      "options": { "baseURL": "http://127.0.0.1:9/v1" },
      "models": { "Qwen3.6-35B-A3B-4bit": { "name": "Qwen3.6-35B-A3B-4bit" } }
    }
  }
}
JSON
original_sha="$(shasum -a 256 "$home/.config/opencode/opencode.json" | cut -d' ' -f1)"
v1_block="$(python3 -c 'import sys; t=open(sys.argv[1]).read(); s=t.index("  \"provider\""); print(t[s:t.index("\n  }", s) + 4])' "$home/.config/opencode/opencode.json")"
write_config "$home" "$work/writer-owner.log" || { tail -40 "$work/writer-owner.log"; fail "the writer ran on the owner's file"; }
config="$(result "$home" file)"
check "the owner's opencode.json is the file edited" [ "$config" = "$home/.config/opencode/opencode.json" ]
check "a backup was made" [ -f "$(result "$home" backup)" ]
check "the owner's default model is kept" \
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["model"] == "omlx/Qwen3.6-35B-A3B-4bit" else 1)' "$config"
check "the V1 provider block is byte for byte the same" python3 -c 'import sys; sys.exit(0 if sys.argv[2] in open(sys.argv[1]).read() else 1)' "$config" "$v1_block"
check "the file is still strict JSON with no comment" bash -c 'python3 -m json.tool "$1" > /dev/null && ! grep -q "// Added" "$1"' _ "$config"
run_opencode "$home" models --standalone > "$work/models-owner.txt" 2>&1 || true
check "opencode models lists the owner's omlx model" grep -q '^omlx/Qwen3.6-35B-A3B-4bit$' "$work/models-owner.txt"
check "opencode models lists $provider/qwen3.8-27b beside it" grep -q "^$provider/qwen3.8-27b\$" "$work/models-owner.txt"
(cd "$work" && eval "$(result "$home" undo)")
check "the printed undo puts the owner's file back exactly" \
    [ "$(shasum -a 256 "$home/.config/opencode/opencode.json" | cut -d' ' -f1)" = "$original_sha" ]

# 3. No file Darkbloom wrote holds the key: the configs and the backups (Darkbloom's own key files hold it by design).
written="$(find "$work/home" "$work/home-owner" -type f \( -name 'opencode.json*' -o -path '*/integrations/backups/*' \))"
check "no config or backup Darkbloom wrote holds the key" bash -c '! grep -lF "$1" $2' _ "$token" "$written"

echo "$failures failure(s)"
[[ $failures == 0 ]]
