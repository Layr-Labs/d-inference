"""Bounded CLI execution and private, replayable acceptance-test evidence."""

from datetime import datetime, timezone
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time
from urllib.parse import urlsplit
import uuid

MAX_CAPTURE = 8 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def utc():
    return datetime.now(timezone.utc).isoformat()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def identity(value):
    require(isinstance(value, str) and str(uuid.UUID(value)) == value.lower(), "invalid UUID response")
    return value


def validate_config(config):
    allowed = {"environment", "api_url", "cli", "base_image_id", "host_id", "cpu", "memory_gib",
               "workspace_gib", "readiness_seconds", "expiry_seconds", "allow_insecure_localhost", "workspace_exhaustion"}
    require(set(config) <= allowed, "configuration contains unknown fields (never put credentials in configuration)")
    require(config.get("environment") == "nonproduction", "explicit nonproduction environment required")
    origin = urlsplit(config["api_url"])
    require(origin.hostname and not origin.username and not origin.password and not origin.query
            and not origin.fragment and origin.path in ("", "/"), "API must be an origin without credentials")
    require(origin.hostname.lower().rstrip(".") not in {"api.darkbloom.dev", "api.darkbloom.ai"},
            "production coordinator is forbidden")
    try:
        loopback = ipaddress.ip_address(origin.hostname).is_loopback
    except ValueError:
        loopback = origin.hostname.lower() == "localhost"
    require(origin.scheme == "https" or (origin.scheme == "http" and loopback
            and config.get("allow_insecure_localhost") is True), "HTTPS required except explicit loopback HTTP")
    identity(config["host_id"])
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", config["base_image_id"]), "invalid image ID")
    cli = Path(config["cli"])
    require(cli.is_absolute() and cli.is_file() and not cli.is_symlink() and os.access(cli, os.X_OK),
            "CLI must be an explicit executable regular file")
    for field, default, minimum, maximum in [("cpu", 4, 1, 64), ("memory_gib", 8, 2, 512),
            ("readiness_seconds", 600, 30, 1800), ("expiry_seconds", 2100, 30, 3600)]:
        value = config.get(field, default)
        require(type(value) is int and minimum <= value <= maximum, "invalid " + field)
    require(config.get("workspace_gib", 25) in (25, 50), "invalid workspace capacity")
    require(type(config.get("workspace_exhaustion", False)) is bool, "workspace_exhaustion must be a boolean")
    return config


class EvidenceCLI:
    def __init__(self, config, output, key):
        self.config = validate_config(config)
        require(key and not any(c.isspace() for c in key), "DARKBLOOM_API_KEY is required")
        self.key = key
        self.root = Path(output).absolute()
        self.root.mkdir(mode=0o700, parents=False, exist_ok=False)
        os.chmod(self.root, 0o700)
        self.lock = threading.Lock()
        self.sequence = 0
        self.records = []
        self.write("configuration.json", config)
        self.write("provenance.json", {"started_at": utc(), "cli_sha256": digest(Path(config["cli"]).read_bytes()),
            "harness_sha256": {p.name: digest(p.read_bytes()) for p in
                [Path(__file__).parent / "test-sandbox-live.py"] + list(Path(__file__).parent.glob("sandbox_live_*.py"))},
            "host_identity_evidence": "operator_supplied; CLI does not expose host assignment",
            "physical_vm_removal_evidence": "API terminal state only; host inventory must be collected separately"})

    def write(self, name, value):
        data = json.dumps(value, sort_keys=True, indent=2).encode() + b"\n"
        temporary = self.root / ("." + str(uuid.uuid4()))
        with temporary.open("xb") as handle:
            os.chmod(temporary, 0o600)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, self.root / name)
        directory = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

    def call(self, label, args, *, key=None, timeout=60):
        args = [str(a) for a in args]
        with self.lock:
            self.sequence += 1
            stem = f"{self.sequence:04d}-{label}"
        require(re.fullmatch(r"[0-9A-Za-z_-]+", stem), "unsafe evidence label")
        argv = [self.config["cli"], "--json", "--api-url", self.config["api_url"]]
        if self.config.get("allow_insecure_localhost"):
            argv += ["--allow-insecure-localhost"]
        if key:
            argv += ["--idempotency-key", identity(key)]
        argv += [str(a) for a in args]
        # Do not inherit unrelated cloud/service credentials or a default origin.
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                       "DARKBLOOM_API_KEY": self.key}
        streams = {"stdout": bytearray(), "stderr": bytearray()}
        overflow = threading.Event()
        started = time.monotonic()
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
                                   stdin=subprocess.DEVNULL, start_new_session=True)

        def drain(name, pipe):
            while True:
                chunk = pipe.read(65536)
                if not chunk:
                    break
                remaining = MAX_CAPTURE - len(streams[name])
                streams[name].extend(chunk[:max(remaining, 0)])
                if len(chunk) > remaining:
                    overflow.set()
            pipe.close()

        readers = [threading.Thread(target=drain, args=(name, getattr(process, name)), daemon=True)
                   for name in streams]
        for reader in readers:
            reader.start()
        interrupted = False
        interruption_error = None
        try:
            while process.poll() is None:
                if overflow.is_set() or time.monotonic() - started > timeout:
                    interrupted = True
                    break
                time.sleep(0.05)
        except BaseException as error:
            interrupted = True
            interruption_error = error
        finally:
            if process.poll() is None:
                # Signal only this harness-created CLI; it cancels its own wait.
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            for reader in readers:
                reader.join(timeout=5)
        require(not any(t.is_alive() for t in readers), "CLI output pipe did not close")
        record = {"label": label, "arguments": args, "idempotency_key": key,
                  "exit_code": process.returncode, "duration_seconds": time.monotonic() - started,
                  "interrupted": interrupted, "capture_truncated": overflow.is_set(), "finished_at": utc()}
        for name, data in streams.items():
            path = self.root / (stem + "." + name)
            with path.open("xb") as handle:
                os.chmod(path, 0o600)
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            record[name] = {"path": path.name, "bytes": len(data), "sha256": digest(data)}
        self.write(stem + ".json", record)
        with self.lock:
            self.records.append(record)
        if interruption_error is not None:
            raise interruption_error
        try:
            payload = json.loads(streams["stdout"])
        except (ValueError, UnicodeDecodeError):
            payload = None
        return record, payload


def success(result):
    record, payload = result
    require(record["exit_code"] == 0 and not record["interrupted"] and not record["capture_truncated"],
            "CLI request failed; see raw evidence")
    require(isinstance(payload, dict), "CLI response is not a JSON object")
    return payload


def denied(result, code):
    record, payload = result
    require(record["exit_code"] != 0 and not record["interrupted"] and not record["capture_truncated"],
            "expected explicit API denial, not transport interruption")
    require(isinstance(payload, dict) and payload.get("error") == f"sandbox request failed: {code} (HTTP 404)",
            "unexpected denial reason; positive control or API behavior failed")
