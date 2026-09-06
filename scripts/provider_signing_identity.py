#!/usr/bin/env python3
"""Isolated-keychain lifecycle and public Developer ID identity selection.

This helper never imports/exports a private key, reads a signing secret, changes
trust settings, or selects from a global identity search. The workflow owns
secret import; this helper records public metadata and fails closed.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

MAX_METADATA_BYTES = 64 * 1024
MAX_IDENTITIES = 16
KEYCHAIN_NAME = "signing-validation.keychain-db"
DEVELOPER_ID_APPLICATION_OID = "1.2.840.113635.100.6.1.13"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def security(*arguments):
    return subprocess.run(["security", *arguments], check=True, capture_output=True, text=True, timeout=30).stdout


def path_string(value):
    require(isinstance(value, str) and value and Path(value).is_absolute()
            and all(character.isprintable() for character in value), "invalid keychain path")
    return value


def search_list(text):
    require(len(text.encode()) <= MAX_METADATA_BYTES, "keychain search-list metadata limit")
    values = shlex.split(text)
    require(len(values) <= 64 and len(set(values)) == len(values), "invalid keychain search list")
    return [path_string(value) for value in values]


def write_json(path, value, exclusive=False):
    payload = json.dumps(value, indent=2, ensure_ascii=True) + "\n"
    if exclusive:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as output:
            output.write(payload)
    else:
        temporary = path.with_name(path.name + ".tmp")
        temporary.write_text(payload)
        temporary.chmod(0o600)
        temporary.replace(path)


def snapshot(path):
    require(path.stat().st_size <= MAX_METADATA_BYTES, "keychain snapshot metadata limit")
    value = json.loads(path.read_text())
    require(set(value) == {"schema", "domain", "temporary_keychain", "original_search_list"}
            and value["schema"] == 1 and value["domain"] == "user", "invalid keychain snapshot")
    temporary = Path(path_string(value["temporary_keychain"]))
    require(temporary.name == KEYCHAIN_NAME and temporary.parent == path.parent,
            "temporary keychain is outside the captured scope")
    original = value["original_search_list"]
    require(isinstance(original, list) and len(original) <= 64 and len(set(original)) == len(original),
            "invalid original search list")
    for entry in original:
        path_string(entry)
    require(str(temporary) not in original, "temporary keychain was not new")
    return value


def capture_search_list(path, keychain):
    path_string(str(keychain))
    require(keychain.name == KEYCHAIN_NAME and keychain.parent == path.parent,
            "temporary keychain must share the snapshot directory")
    require(not path.exists() and not keychain.exists(), "refusing existing keychain/snapshot")
    original = search_list(security("list-keychains", "-d", "user"))
    require(str(keychain) not in original, "temporary keychain is already in the search list")
    write_json(path, {"schema": 1, "domain": "user", "temporary_keychain": str(keychain),
                      "original_search_list": original}, exclusive=True)


def activate_search_list(path):
    state = snapshot(path)
    require(Path(state["temporary_keychain"]).is_file(), "temporary keychain was not created")
    expected = [state["temporary_keychain"], *state["original_search_list"]]
    security("list-keychains", "-d", "user", "-s", *expected)
    require(search_list(security("list-keychains", "-d", "user")) == expected,
            "temporary keychain search-list activation failed")


def parse_valid_identities(text):
    require(len(text.encode()) <= MAX_METADATA_BYTES, "identity metadata limit")
    identities, reported = [], None
    for line in text.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'\s*(\d+)\)\s+([0-9A-Fa-f]{40})\s+"([^"\r\n]+)"\s*', line)
        if match:
            require(reported is None and int(match[1]) == len(identities) + 1,
                    "identity listing order is inconsistent")
            require(all(c.isprintable() for c in match[3]), "identity name contains control characters")
            identities.append({"sha1": match[2].upper(), "name": match[3]})
            require(len(identities) <= MAX_IDENTITIES, "too many identities")
            continue
        count = re.fullmatch(r'\s*(\d+) valid identit(?:y|ies) found\s*', line)
        require(count is not None and reported is None, "unrecognized identity listing")
        reported = int(count[1])
    require(reported is not None and reported == len(identities), "identity count mismatch")
    require(len({entry["sha1"] for entry in identities}) == len(identities), "duplicate identity fingerprint")
    return identities


def code_requirement(team):
    require(re.fullmatch(r'[A-Z0-9]{10}', team) is not None, "invalid expected team")
    return ('anchor apple generic and certificate leaf[field.' + DEVELOPER_ID_APPLICATION_OID
            + '] exists and certificate leaf[subject.OU] = "' + team + '"')


def select_identity(identities, team):
    code_requirement(team)
    require(len(identities) == 1, "expected exactly one valid codesigning identity in the isolated keychain")
    selected = identities[0]
    match = re.fullmatch(r'Developer ID Application: (.+) \(([A-Z0-9]{10})\)', selected["name"])
    require(match is not None and match[1].strip(), "identity is not Developer ID Application")
    require(match[2] == team, "Developer ID Application identity has the wrong team")
    return selected


def record_identity(path, team, output, github_env):
    state = snapshot(path)
    receipt = {"schema": 1, "expected_team": team, "status": "rejected", "valid_identities": []}
    try:
        current = search_list(security("list-keychains", "-d", "user"))
        require(current == [state["temporary_keychain"], *state["original_search_list"]],
                "isolated keychain search list was not activated")
        text = security("find-identity", "-v", "-p", "codesigning", state["temporary_keychain"])
        receipt["valid_identities"] = parse_valid_identities(text)
        selected = select_identity(receipt["valid_identities"], team)
        requirement = code_requirement(team)
        receipt.update(status="selected", selected=selected, signed_code_requirement=requirement,
                       private_key_check="security find-identity -v -p codesigning",
                       identity_scope="isolated imported keychain only")
        # Only public, validated ASCII fingerprint and fixed-policy requirement
        # enter the environment; no subject, password or key data is exported.
        with github_env.open("a") as stream:
            stream.write("SIGNING_IDENTITY_SHA1=" + selected["sha1"] + "\n")
            stream.write("SIGNING_REQUIREMENT=" + requirement + "\n")
    except Exception as error:
        receipt["status"] = "rejected"
        receipt["error"] = str(error)
        raise
    finally:
        write_json(output, receipt)


def cleanup_keychain(path, output):
    receipt = {"schema": 1, "status": "not_created", "search_list_restored": False,
               "temporary_keychain_deleted": False}
    if not path.exists():
        write_json(output, receipt)
        return
    errors = []
    temporary = path.parent / KEYCHAIN_NAME
    try:
        state = snapshot(path)
        security("list-keychains", "-d", "user", "-s", *state["original_search_list"])
        require(search_list(security("list-keychains", "-d", "user")) == state["original_search_list"],
                "original keychain search list was not restored")
        receipt["search_list_restored"] = True
    except Exception as error:
        errors.append("search-list restore: " + str(error))
    try:
        # This is the fixed temporary name in the captured workflow directory,
        # never a deletion target accepted from malformed snapshot data.
        if temporary.exists():
            security("delete-keychain", str(temporary))
        require(not temporary.exists(), "temporary keychain still exists")
        receipt["temporary_keychain_deleted"] = True
    except Exception as error:
        errors.append("temporary-keychain deletion: " + str(error))
    finally:
        for name in ("signing-certificate.p12", "profile.plist"):
            try:
                (path.parent / name).unlink(missing_ok=True)
            except Exception as error:
                errors.append("temporary-file removal: " + str(error))
        receipt.update(status="cleaned" if not errors else "failed", errors=errors)
        write_json(output, receipt)
    require(not errors, "signing keychain cleanup failed; see the non-secret cleanup receipt")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("capture")
    capture.add_argument("--snapshot", type=Path, required=True)
    capture.add_argument("--keychain", type=Path, required=True)
    activate = commands.add_parser("activate")
    activate.add_argument("--snapshot", type=Path, required=True)
    select = commands.add_parser("select")
    for name in ("snapshot", "output", "github-env"):
        select.add_argument("--" + name, type=Path, required=True)
    select.add_argument("--team", required=True)
    cleanup = commands.add_parser("cleanup")
    cleanup.add_argument("--snapshot", type=Path, required=True)
    cleanup.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "capture": capture_search_list(args.snapshot, args.keychain)
    elif args.command == "activate": activate_search_list(args.snapshot)
    elif args.command == "select": record_identity(args.snapshot, args.team, args.output, args.github_env)
    else: cleanup_keychain(args.snapshot, args.output)


if __name__ == "__main__":
    main()
