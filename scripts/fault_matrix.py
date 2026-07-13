"""Signed executable fault-matrix receipt generation and validation."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import stat
import subprocess
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any, Mapping, Sequence


class FaultMatrixError(ValueError):
    """A registry, receipt, signature, or executable coverage check failed."""


def build_report(
    receipt_directory: Path,
    trusted_public_key: Path,
    *,
    expected_commit: str | None = None,
) -> dict[str, Any]:
    registry_envelope = _load_object(receipt_directory / "instrumentation-registry.json")
    registry = _verify_envelope(registry_envelope, trusted_public_key)
    _require_header(registry, "fault-instrumentation-registry")
    run_id = _nonempty_string(registry.get("run_id"), "registry run id")
    commit = _nonempty_string(registry.get("commit"), "registry commit")
    _positive_integer(registry.get("process_id"), "registry process id")
    if expected_commit is not None and commit != expected_commit:
        raise FaultMatrixError(
            f"registry commit {commit!r} does not match expected commit {expected_commit!r}"
        )

    hooks = registry.get("hooks")
    if not isinstance(hooks, list) or not hooks:
        raise FaultMatrixError("instrumentation registry has no hooks")
    definitions: dict[str, Mapping[str, Any]] = {}
    for hook in hooks:
        if not isinstance(hook, dict):
            raise FaultMatrixError("instrumentation hook must be an object")
        hook_id = _nonempty_string(hook.get("id"), "instrumentation hook id")
        if hook_id in definitions:
            raise FaultMatrixError(f"duplicate instrumentation hook {hook_id}")
        _nonempty_string(hook.get("file"), f"{hook_id} source file")
        _nonempty_string(hook.get("symbol"), f"{hook_id} symbol")
        if hook.get("kind") not in {"async", "sync"}:
            raise FaultMatrixError(f"{hook_id} has invalid execution kind")
        guarantees = hook.get("guarantees")
        if not isinstance(guarantees, list) or not guarantees:
            raise FaultMatrixError(f"{hook_id} has no recovery guarantees")
        if any(not isinstance(value, str) or not value for value in guarantees):
            raise FaultMatrixError(f"{hook_id} has invalid recovery guarantees")
        definitions[hook_id] = hook

    receipt_envelopes: list[dict[str, Any]] = []
    receipts: list[Mapping[str, Any]] = []
    test_ids: set[str] = set()
    for path in sorted(receipt_directory.glob("receipt-*.json")):
        envelope = _load_object(path)
        receipt = _verify_envelope(envelope, trusted_public_key)
        _require_header(receipt, "fault-test-receipt")
        if receipt.get("run_id") != run_id:
            raise FaultMatrixError(f"{path.name} was produced by a different fault run")
        if receipt.get("commit") != commit:
            raise FaultMatrixError(f"{path.name} was produced for a different commit")
        _positive_integer(receipt.get("process_id"), f"{path.name} process id")
        test_id = _nonempty_string(receipt.get("test_id"), f"{path.name} test id")
        if test_id in test_ids:
            raise FaultMatrixError(f"duplicate fault receipt test id {test_id}")
        test_ids.add(test_id)
        assertions = receipt.get("invariant_assertions")
        if not isinstance(assertions, list) or not assertions:
            raise FaultMatrixError(f"{test_id} has no invariant assertions")
        for assertion in assertions:
            if (
                not isinstance(assertion, dict)
                or not isinstance(assertion.get("id"), str)
                or not assertion.get("id")
                or assertion.get("passed") is not True
            ):
                raise FaultMatrixError(f"{test_id} contains a failed invariant assertion")
        receipt_hooks = receipt.get("hooks")
        if not isinstance(receipt_hooks, list) or not receipt_hooks:
            raise FaultMatrixError(f"{test_id} has no hook hits")
        receipt_hook_ids: set[str] = set()
        for receipt_hook in receipt_hooks:
            if not isinstance(receipt_hook, dict):
                raise FaultMatrixError(f"{test_id} contains a malformed hook receipt")
            receipt_hook_id = _nonempty_string(
                receipt_hook.get("hook_id"), f"{test_id} receipt hook id"
            )
            if receipt_hook_id not in definitions:
                raise FaultMatrixError(
                    f"{test_id} reports unknown production hook {receipt_hook_id}"
                )
            if receipt_hook_id in receipt_hook_ids:
                raise FaultMatrixError(
                    f"{test_id} reports duplicate production hook {receipt_hook_id}"
                )
            receipt_hook_ids.add(receipt_hook_id)
        receipt_envelopes.append(envelope)
        receipts.append(receipt)

    boundaries: list[dict[str, Any]] = []
    for hook_id, definition in definitions.items():
        validators: list[str] = []
        total_hits = 0
        observed_sites: list[dict[str, Any]] = []
        action_validators: dict[str, set[str]] = {}
        action_outcomes: dict[str, set[str]] = {}
        action_processes: dict[str, set[int]] = {}
        required_guarantees = set(definition["guarantees"])
        for receipt in receipts:
            asserted = {
                assertion["id"]
                for assertion in receipt["invariant_assertions"]
                if assertion["passed"] is True
            }
            for hit in receipt["hooks"]:
                if not isinstance(hit, dict) or hit.get("hook_id") != hook_id:
                    continue
                hit_count = hit.get("hit_count")
                if not isinstance(hit_count, int) or isinstance(hit_count, bool) or hit_count <= 0:
                    raise FaultMatrixError(
                        f"{receipt['test_id']} reports a non-positive hit count for {hook_id}"
                    )
                executions = hit.get("executions")
                if (
                    not isinstance(executions, list)
                    or not executions
                    or len(executions) != hit_count
                ):
                    raise FaultMatrixError(
                        f"{receipt['test_id']} execution count does not match hits for {hook_id}"
                    )
                for execution in executions:
                    action, outcome, process_id, site = _validate_execution(
                        hook_id,
                        definition,
                        execution,
                        receipt["test_id"],
                        run_id,
                        commit,
                    )
                    _validate_runtime_site(hook_id, definition, site, receipt["test_id"])
                    if site not in observed_sites:
                        observed_sites.append(site)
                    action_validators.setdefault(action, set()).add(receipt["test_id"])
                    action_outcomes.setdefault(action, set()).add(outcome)
                    action_processes.setdefault(action, set()).add(process_id)
                missing = required_guarantees - asserted
                if missing:
                    raise FaultMatrixError(
                        f"{receipt['test_id']} hit {hook_id} without assertions "
                        f"for {sorted(missing)}"
                    )
                total_hits += hit_count
                validators.append(receipt["test_id"])
        if not validators:
            raise FaultMatrixError(f"uncovered production fault hook {hook_id}")
        actions = sorted(action_validators)
        boundaries.append(
            {
                "hook_id": hook_id,
                "file": definition["file"],
                "symbol": definition["symbol"],
                "kind": definition["kind"],
                "actions": actions,
                "action_evidence": [
                    {
                        "action": action,
                        "outcomes": sorted(action_outcomes[action]),
                        "process_ids": sorted(action_processes[action]),
                        "validators": sorted(action_validators[action]),
                    }
                    for action in actions
                ],
                "hit_count": total_hits,
                "validators": sorted(set(validators)),
                "invariant_assertions": sorted(required_guarantees),
                "observed_sites": observed_sites,
            }
        )

    return {
        "schema_version": 1,
        "objective": 9,
        "artifact": "fault-matrix-report",
        "run_id": run_id,
        "commit": commit,
        "signer_key_id": _public_key_id(trusted_public_key),
        "boundary_count": len(boundaries),
        "coverage": sorted(
            {
                guarantee
                for definition in definitions.values()
                for guarantee in definition["guarantees"]
            }
        ),
        "tested_actions": sorted(
            {
                action
                for boundary in boundaries
                for action in boundary["actions"]
            }
        ),
        "boundaries": boundaries,
        "signed_registry": registry_envelope,
        "signed_receipts": receipt_envelopes,
    }


def validate_report(report: Mapping[str, Any], trusted_public_key: Path) -> dict[str, Any]:
    if report.get("schema_version") != 1 or report.get("artifact") != "fault-matrix-report":
        raise FaultMatrixError("unsupported fault matrix report")
    with tempfile.TemporaryDirectory(prefix="darkbloom-fault-import-") as temporary:
        directory = Path(temporary)
        _write_json(directory / "instrumentation-registry.json", report.get("signed_registry"))
        receipts = report.get("signed_receipts")
        if not isinstance(receipts, list):
            raise FaultMatrixError("fault matrix report has no signed receipts")
        for index, receipt in enumerate(receipts):
            _write_json(directory / f"receipt-{index:04d}.json", receipt)
        rebuilt = build_report(
            directory,
            trusted_public_key,
            expected_commit=_nonempty_string(report.get("commit"), "report commit"),
        )
    comparable = dict(report)
    if rebuilt != comparable:
        raise FaultMatrixError("fault matrix report does not match its signed receipt inputs")
    return rebuilt


def run_and_build(
    command: Sequence[str],
    output: Path,
    signing_key: Path,
    trusted_public_key: Path,
) -> int:
    if not command:
        raise FaultMatrixError("fault test command is required")
    _validate_private_key(signing_key)
    if _private_key_id(signing_key) != _public_key_id(trusted_public_key):
        raise FaultMatrixError("fault receipt signing key does not match the trusted public key")
    commit = _git_commit()
    run_id = secrets.token_hex(16)
    with tempfile.TemporaryDirectory(prefix="darkbloom-fault-run-") as temporary:
        root = Path(temporary)
        receipts = root / "receipts"
        environment = _fault_test_environment()
        environment.update(
            {
                "DARKBLOOM_FAULT_RECEIPT_DIR": str(receipts),
                "DARKBLOOM_FAULT_RECEIPT_SIGNING_KEY": str(signing_key.resolve()),
                "DARKBLOOM_FAULT_RECEIPT_RUN_ID": run_id,
                "DARKBLOOM_FAULT_RECEIPT_COMMIT": commit,
            }
        )
        completed = subprocess.run(list(command), check=False, env=environment)
        if completed.returncode != 0:
            return completed.returncode or 2
        report = build_report(receipts, trusted_public_key, expected_commit=commit)
        _write_json(output, report)
    return 0


def _fault_test_environment(
    source: Mapping[str, str] | None = None,
) -> dict[str, str]:
    values = os.environ if source is None else source
    forbidden = sorted(
        name
        for name in ("DATABASE_URL", "EIGENINFERENCE_DATABASE_URL", "PGSERVICE")
        if values.get(name)
    )
    if forbidden:
        raise FaultMatrixError(
            "runtime database credential variables are forbidden: " + ", ".join(forbidden)
        )
    sensitive_markers = (
        "PASSWORD",
        "TOKEN",
        "SECRET",
        "API_KEY",
        "APPLICATION_KEY",
        "PRIVATE_KEY",
        "MNEMONIC",
        "CREDENTIAL",
    )
    environment = {
        key: value
        for key, value in values.items()
        if not any(marker in key.upper() for marker in sensitive_markers)
        and key != "DARKBLOOM_TEST_DATABASE_URL"
    }
    test_database = values.get("DARKBLOOM_TEST_DATABASE_URL")
    if test_database:
        hostname = urllib.parse.urlsplit(test_database).hostname
        if hostname not in {"localhost", "127.0.0.1", "::1"}:
            raise FaultMatrixError("DARKBLOOM_TEST_DATABASE_URL must use loopback")
        environment["DARKBLOOM_TEST_DATABASE_URL"] = test_database
    return environment


def _validate_execution(
    hook_id: str,
    definition: Mapping[str, Any],
    execution: Any,
    test_id: str,
    run_id: str,
    commit: str,
) -> tuple[str, str, int, Any]:
    if not isinstance(execution, dict):
        raise FaultMatrixError(f"{test_id} has a malformed execution for {hook_id}")
    armed_action = execution.get("armed_action")
    executed_action = execution.get("executed_action")
    outcome = execution.get("outcome")
    valid_outcomes = {
        "fail": {"failure_returned"},
        "delay": {"delay_released", "delay_blocked"},
        "crash": {"supervisor_panicked", "process_aborted"},
    }
    if (
        armed_action not in valid_outcomes
        or executed_action != armed_action
        or outcome not in valid_outcomes[executed_action]
    ):
        raise FaultMatrixError(
            f"{test_id} armed action, executed action, and outcome do not match for {hook_id}"
        )
    action = executed_action
    if action == "delay" and definition.get("kind") != "async":
        raise FaultMatrixError(f"{test_id} delayed synchronous hook {hook_id}")
    process_id = _positive_integer(
        execution.get("process_id"), f"{test_id} {hook_id} execution process id"
    )
    if execution.get("hook_id") != hook_id:
        raise FaultMatrixError(f"{test_id} execution hook does not match {hook_id}")
    if execution.get("run_id") != run_id or execution.get("commit") != commit:
        raise FaultMatrixError(
            f"{test_id} execution run or commit does not match receipt for {hook_id}"
        )
    return action, outcome, process_id, execution.get("site")


def _validate_runtime_site(
    hook_id: str,
    definition: Mapping[str, Any],
    site: Any,
    test_id: str,
) -> None:
    if not isinstance(site, dict):
        raise FaultMatrixError(f"{test_id} has a malformed runtime site for {hook_id}")
    file = site.get("file")
    if (
        site.get("hook_id") != hook_id
        or not isinstance(file, str)
        or not file.endswith(str(definition["file"]))
        or site.get("symbol") != definition["symbol"]
        or site.get("kind") != definition["kind"]
        or not isinstance(site.get("module"), str)
        or not site["module"]
        or not isinstance(site.get("line"), int)
        or site["line"] <= 0
    ):
        raise FaultMatrixError(
            f"{test_id} runtime site does not match registry definition for {hook_id}"
        )


def _require_header(payload: Mapping[str, Any], artifact: str) -> None:
    if (
        payload.get("schema_version") != 1
        or payload.get("objective") != 9
        or payload.get("artifact") != artifact
    ):
        raise FaultMatrixError(f"invalid {artifact} header")


def _verify_envelope(
    envelope: Mapping[str, Any], trusted_public_key: Path
) -> dict[str, Any]:
    if set(envelope) != {"schema_version", "signed_payload", "signature"}:
        raise FaultMatrixError("signed fault envelope fields do not match schema 1")
    if envelope.get("schema_version") != 1:
        raise FaultMatrixError("unsupported signed fault envelope")
    signature = envelope.get("signature")
    if not isinstance(signature, dict) or set(signature) != {
        "algorithm",
        "key_id",
        "value",
    }:
        raise FaultMatrixError("malformed fault receipt signature")
    if signature.get("algorithm") != "openssl-dgst-sha256":
        raise FaultMatrixError("unsupported fault receipt signature algorithm")
    if signature.get("key_id") != _public_key_id(trusted_public_key):
        raise FaultMatrixError("fault receipt signer is not trusted")
    try:
        payload = base64.b64decode(envelope["signed_payload"], validate=True)
        raw_signature = base64.b64decode(signature["value"], validate=True)
    except (KeyError, TypeError, ValueError) as error:
        raise FaultMatrixError("fault receipt envelope is not valid base64") from error
    with tempfile.NamedTemporaryFile() as signature_file:
        signature_file.write(raw_signature)
        signature_file.flush()
        completed = subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(trusted_public_key),
                "-signature",
                signature_file.name,
            ],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    if completed.returncode != 0:
        raise FaultMatrixError("fault receipt signature verification failed")
    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError as error:
        raise FaultMatrixError("signed fault payload is not JSON") from error
    if not isinstance(decoded, dict):
        raise FaultMatrixError("signed fault payload must be an object")
    return decoded


def _public_key_id(path: Path) -> str:
    completed = subprocess.run(
        ["openssl", "pkey", "-pubin", "-in", str(path), "-outform", "DER"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise FaultMatrixError("cannot read trusted fault receipt public key")
    return hashlib.sha256(completed.stdout).hexdigest()


def _private_key_id(path: Path) -> str:
    completed = subprocess.run(
        ["openssl", "pkey", "-in", str(path), "-pubout", "-outform", "DER"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise FaultMatrixError("cannot read fault receipt signing key")
    return hashlib.sha256(completed.stdout).hexdigest()


def _validate_private_key(path: Path) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise FaultMatrixError(f"cannot inspect fault receipt signing key: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise FaultMatrixError("fault receipt signing key must be a regular non-symlink file")
    if metadata.st_mode & 0o077:
        raise FaultMatrixError("fault receipt signing key permissions must be 0600 or stricter")


def _load_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FaultMatrixError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise FaultMatrixError(f"{path} must contain an object")
    return value


def _write_json(path: Path, value: Any) -> None:
    if not isinstance(value, (dict, list)):
        raise FaultMatrixError(f"refusing to write malformed JSON artifact {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _nonempty_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise FaultMatrixError(f"{field} must be a non-empty string")
    return value


def _positive_integer(value: Any, field: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise FaultMatrixError(f"{field} must be a positive integer")
    return value


def _git_commit() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        raise FaultMatrixError("cannot determine fault test commit")
    return completed.stdout.decode("ascii").strip()


def main(arguments: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="subcommand", required=True)
    run = commands.add_parser("run")
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--signing-key", type=Path, required=True)
    run.add_argument("--trusted-key", type=Path, required=True)
    run.add_argument("test_command", nargs=argparse.REMAINDER)
    validate = commands.add_parser("validate")
    validate.add_argument("--source", type=Path, required=True)
    validate.add_argument("--trusted-key", type=Path, required=True)
    options = parser.parse_args(arguments)
    try:
        if options.subcommand == "run":
            command = list(options.test_command)
            if command and command[0] == "--":
                command = command[1:]
            return run_and_build(
                command,
                options.output,
                options.signing_key,
                options.trusted_key,
            )
        validate_report(_load_object(options.source), options.trusted_key)
        return 0
    except (FaultMatrixError, OSError) as error:
        print(f"fault-matrix: {error}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
