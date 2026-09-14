"""Bounded file REST probes where the consumer CLI batches multiple requests."""

import http.client
import json
import re
import socket
import threading
import time
from urllib.parse import urlencode, urlsplit

from sandbox_live_evidence import digest, identity, require, utc

CHUNK_BYTES = 524288
RESPONSE_HEADERS = {"content-type", "content-length", "cache-control", "x-sandbox-file-size",
                    "x-sandbox-file-offset", "x-sandbox-chunk-sha256", "x-sandbox-file-version"}


class FileAPI:
    def __init__(self, suite):
        self.suite = suite
        self.client = suite.client

    def call(self, label, sandbox_id, operation, *, transfer_id=None, query=None, body=None):
        require(sandbox_id in self.suite.created, "REST probe requires a sandbox created by this run")
        identity(sandbox_id)
        operations = {"begin": ("POST", "/files/uploads"), "chunk": ("PUT", "/files/uploads/{id}/chunks"),
                      "download": ("GET", "/files")}
        require(operation in operations, "unsupported REST probe")
        method, suffix = operations[operation]
        if operation == "chunk":
            suffix = suffix.format(id=identity(transfer_id))
        require(transfer_id is None or operation == "chunk", "unexpected transfer identity")
        query = query or {}
        require(set(query) <= ({"offset"} if operation == "chunk" else
                {"path", "offset", "length", "version"} if operation == "download" else set()),
                "unsupported file query")
        if operation == "begin":
            require(isinstance(body, dict) and set(body) == {"transfer_id", "path", "size", "sha256"},
                    "unexpected upload metadata")
            identity(body["transfer_id"])
            encoded = json.dumps(body).encode()
        else:
            encoded = body or b""
        require(isinstance(encoded, bytes) and len(encoded) <= CHUNK_BYTES, "oversized REST request")
        require(operation != "download" or not encoded, "download cannot carry request bytes")
        path = "/v1/sandboxes/" + sandbox_id + suffix
        if query:
            path += "?" + urlencode(query)
        origin = urlsplit(self.client.config["api_url"])
        # http.client does not consult ambient proxy credentials or follow redirects.
        connection_type = http.client.HTTPSConnection if origin.scheme == "https" else http.client.HTTPConnection
        connection = connection_type(origin.hostname, origin.port, timeout=10)
        stem = self.client.evidence_stem(label)
        record = {"label": label, "transport": "consumer_file_rest", "method": method, "path": path,
                  "request_bytes": len(encoded), "request_sha256": digest(encoded), "evidence_file": stem + ".json"}
        started = time.monotonic()
        data, headers, status, failure = b"", {}, None, None
        watchdog = None
        try:
            connection.connect()
            transport = connection.sock
            def expire():
                try:
                    transport.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            # A fixed wall-clock bound also stops trickling response headers/body.
            watchdog = threading.Timer(40, expire)
            watchdog.daemon = True
            watchdog.start()
            transport.settimeout(40)
            connection.request(method, path, body=encoded or None, headers={
                "Authorization": "Bearer " + self.client.key,
                "Content-Type": "application/json" if operation == "begin" else "application/octet-stream"})
            response = connection.getresponse()
            status = response.status
            headers = {name.lower(): value for name, value in response.getheaders()
                       if name.lower() in RESPONSE_HEADERS}
            data = response.read(CHUNK_BYTES + 1)
            if len(data) > CHUNK_BYTES:
                failure = "response_exceeds_chunk_bound"
                data = data[:CHUNK_BYTES]
        except (OSError, http.client.HTTPException):
            failure = "file_transport_failed_outcome_may_be_uncertain"
        finally:
            if watchdog is not None:
                watchdog.cancel()
            connection.close()
            # Only a fixed response-header allowlist is recorded; auth is never persisted.
            retained = data.replace(self.client.key.encode(), b"[REDACTED]")
            retained = retained.replace(json.dumps(self.client.key)[1:-1].encode(), b"[REDACTED]")
            safe_headers = {name: value.replace(self.client.key, "[REDACTED]") for name, value in headers.items()}
            record.update(status=status, headers=safe_headers, failure=failure, duration_seconds=time.monotonic() - started,
                          finished_at=utc(), response_bytes=len(data), response_sha256=digest(data),
                          response_redacted=retained != data, response_hex=retained.hex(),
                          retained_response_sha256=digest(retained))
            self.client.write(stem + ".json", record)
            with self.client.lock:
                self.client.records.append(record)
        require(failure is None, "REST probe failed; see bounded evidence")
        return status, headers, data


def json_success(result):
    status, _, data = result
    require(status == 200, "file REST request failed; see raw evidence")
    value = json.loads(data)
    require(isinstance(value, dict), "file REST metadata is not an object")
    return value


def file_denied(result, code):
    status, _, data = result
    require(status == 409 and json.loads(data).get("error", {}).get("code") == code,
            "file REST did not return the expected explicit conflict")


def download_chunk(result, expected, offset, total):
    status, headers, data = result
    require(status == 200 and data == expected and headers.get("content-length") == str(len(expected))
            and headers.get("x-sandbox-file-size") == str(total)
            and headers.get("x-sandbox-file-offset") == str(offset)
            and headers.get("x-sandbox-chunk-sha256") == digest(expected)
            and headers.get("cache-control") == "no-store", "download chunk bytes or metadata differ")
    version = headers.get("x-sandbox-file-version", "")
    require(re.fullmatch(r"[0-9a-f]{64}", version), "download version missing or malformed")
    return version
