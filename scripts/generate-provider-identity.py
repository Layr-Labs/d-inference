#!/usr/bin/env python3
"""Generate the Swift identity and the docs identity tables from provider-identity.json.

provider-swift/identity/provider-identity.json is the only declaration of the
provider identity values. SwiftPM cannot read it at compile time, so this script
writes provider-swift/Sources/ProviderBuildEnvironment/Identity.generated.swift
and the tables between the identity markers in the docs. Run it after every
change to the JSON. With --check it changes nothing and fails when a generated
file differs (scripts/test-provider-identity.py runs it in CI).
"""
import argparse
import difflib
from pathlib import Path
import sys

from provider_release_identity import IDENTITY_FILE, load

ROOT = Path(__file__).resolve().parent.parent
SWIFT = ROOT / "provider-swift/Sources/ProviderBuildEnvironment/Identity.generated.swift"
DOCS = [ROOT / "docs/operations/provider-release.md", ROOT / "docs/developer/build.md"]
SOURCE = "provider-swift/identity/provider-identity.json"
BEGIN = f"<!-- BEGIN provider identity: generated from {SOURCE} by scripts/generate-provider-identity.py; do not edit -->"
END = "<!-- END provider identity -->"

# Swift property order and documentation. The values come only from the JSON.
FIELDS = {
    "coordinatorHTTPURL": "Default coordinator HTTP base URL.",
    "coordinatorWebSocketURL": "Default coordinator provider WebSocket URL.",
    "modelCDNURL": "Must equal the coordinator's MODEL_REGISTRY_CDN_BASE_URL for the same\n"
                   "environment. Dev reads the production CDN, read only.",
    "cliName": "Name of the provider CLI: the executable in the app and the `bin/` link.",
    "enclaveName": "Name of the Secure Enclave helper executable and its `bin/` link.",
    "appBundleName": "Name of the signed app bundle in the install directory.",
    "appDisplayName": "`CFBundleName` of the signed app bundle.",
    "installDirectoryName": "Install and data directory, relative to the home directory.",
    "configDirectoryName": "Configuration directory, relative to the home directory.",
    "legacyConfigDirectoryNames": "Configuration directories from earlier product names.",
    "launchAgentLabel": "launchd label of the provider LaunchAgent.",
    "watchdogAgentLabel": "launchd label of the crash-recovery watchdog LaunchAgent.",
    "logSubsystem": "Unified logging subsystem of the engine and the KV cache.",
    "serviceLogSubsystem": "Unified logging subsystem of the provider service. `logs` and `report`\n"
                           "read this subsystem.",
    "defaultLocalPort": "Default port of the direct-mode local OpenAI endpoint (`start --local`).",
    "keychainServicePrefix": "Prefix of keychain service names and key labels that this install owns.\n"
                             "The keychain access group does not change.",
    "encryptedCacheNamespace": "Directory of this install's encrypted KV cache, in the user cache\n"
                               "directory or in the configured cache directory. Downloaded model\n"
                               "weights are not in it; both installs share them.",
    "modelRevisionRef": "Name of this install's active-revision ref (`refs/<name>`) in the shared\n"
                        "model weights cache. Each install selects its own revision of the shared\n"
                        "weights; a missing ref falls back to production's selection.",
}


def swift_literal(value):
    if isinstance(value, bool):
        raise ValueError("boolean identity values are not supported")
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(swift_literal(item) for item in value) + "]"
    if isinstance(value, str) and all(ch not in value for ch in '"\\\n'):
        return f'"{value}"'
    raise ValueError(f"unsupported identity value: {value!r}")


def swift_type(field, environments):
    value = environments["prod"][field]
    if isinstance(value, int):
        return "UInt16"
    if isinstance(value, list):
        return "[String]"
    return "String"


def validate(document):
    for name, environment in document["environments"].items():
        if set(environment) != set(FIELDS):
            missing = sorted(set(FIELDS) - set(environment))
            extra = sorted(set(environment) - set(FIELDS))
            raise ValueError(f"{name}: fields differ from the Swift identity (missing {missing}, extra {extra})")
        port = environment["defaultLocalPort"]
        if isinstance(port, bool) or not isinstance(port, int) or not 0 < port < 65536:
            raise ValueError(f"{name}: defaultLocalPort must be a TCP port")


def render_swift(document):
    environments = document["environments"]
    lines = [f"// Generated from {SOURCE} by scripts/generate-provider-identity.py.",
             "// Do not edit. Change the JSON and run the script again.", "",
             "extension BuildEnvironment {"]
    for index, (field, doc) in enumerate(FIELDS.items()):
        if index:
            lines.append("")
        lines += ["    /// " + line if line else "    ///" for line in doc.split("\n")]
        lines.append(f"    public var {field}: {swift_type(field, environments)} {{")
        lines.append("        switch self {")
        for name in environments:
            lines.append(f"        case .{name}: return {swift_literal(environments[name][field])}")
        lines += ["        }", "    }"]
    lines += ["}", ""]
    return "\n".join(lines)


def markdown_value(value):
    if isinstance(value, list):
        return ", ".join(f"`{item}`" for item in value) or "none"
    return f"`{value}`"


COLUMN_LABELS = {"prod": "Production", "dev": "Dev", "staging": "Staging"}


def render_table(document):
    environments = document["environments"]
    markers = document["releaseVersionMarkers"]
    columns = list(environments)
    rows = [BEGIN, "",
            "| Field | " + " | ".join(COLUMN_LABELS[name] for name in columns) + " |",
            "|---|" + "---|" * len(columns)]
    for field in FIELDS:
        rows.append("| `" + field + "` | "
                    + " | ".join(markdown_value(environments[name][field]) for name in columns) + " |")
    marker_cells = [f"`{markers[name]}`" if name in markers else "versions without it"
                    for name in columns]
    rows += ["| `releaseVersionMarker` | " + " | ".join(marker_cells) + " |", "", END]
    return "\n".join(rows)


def render_doc(text, table, path):
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        raise ValueError(f"{path}: expected one generated provider identity table")
    start, end = text.index(BEGIN), text.index(END) + len(END)
    return text[:start] + table + text[end:]


def outputs(document):
    validate(document)
    table = render_table(document)
    files = {SWIFT: render_swift(document)}
    for path in DOCS:
        files[path] = render_doc(path.read_text(), table, path)
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if a generated file differs")
    arguments = parser.parse_args()
    stale = []
    for path, content in outputs(load(IDENTITY_FILE)).items():
        current = path.read_text() if path.exists() else ""
        if current == content:
            continue
        if arguments.check:
            stale.append(path)
            sys.stdout.writelines(difflib.unified_diff(
                current.splitlines(True), content.splitlines(True),
                str(path.relative_to(ROOT)), "generated"))
        else:
            path.write_text(content)
            print(f"wrote {path.relative_to(ROOT)}")
    if stale:
        raise SystemExit("provider identity: run scripts/generate-provider-identity.py; stale: "
                         + ", ".join(str(path.relative_to(ROOT)) for path in stale))


if __name__ == "__main__":
    main()
