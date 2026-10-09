#!/usr/bin/env python3
"""Replay packaged native K/V evidence without loading a model.

Example (the output directory must not exist):
  python3 run.py --build-codec-source /path/to/SSDLosslessChunkCodec.swift \
    --input-archive native-inputs.zip --output /path/to/new-replay

Build mode verifies source/driver hashes and invokes /usr/bin/swiftc -O itself.
Alternatively --codec-binary accepts only the archived binary's exact hash.
"""

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import signal
import stat
import subprocess
import sys
import tempfile
import zipfile
import zlib


class EvidenceError(ValueError):
    """An input or probe result does not match the recorded evidence contract."""


@dataclass(frozen=True)
class Packet:
    model: str
    record: dict
    aggregate_hash: str


WIDTHS = {"bfloat16": 2, "float16": 2, "float32": 4}
PROBE_SCHEMA = "darkbloom.production-lossless-codec-benchmark.v1"


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            value.update(chunk)
    return value.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json(data, description):
    try:
        def reject_constant(value):
            raise EvidenceError(f"non-finite JSON number in {description}: {value}")
        return json.loads(data, object_pairs_hook=unique_object, parse_constant=reject_constant)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise EvidenceError(f"invalid JSON in {description}: {error}") from error


def load_json(path):
    return parse_json(Path(path).read_bytes(), str(path))


def checked_hash(value, description):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise EvidenceError(f"invalid SHA-256 for {description}")
    return value


def relative_name(value):
    if (not isinstance(value, str) or not value or any(c in value for c in "\\\x00:")
            or PurePosixPath(value).is_absolute() or str(PurePosixPath(value)) != value
            or any(part in (".", "..") for part in value.split("/"))):
        raise EvidenceError(f"unsafe archive path: {value!r}")
    return value


def input_specs(manifest):
    if not isinstance(manifest, list) or not manifest:
        raise EvidenceError("input manifest must be a nonempty list")
    result = {}
    for row in manifest:
        if not isinstance(row, dict):
            raise EvidenceError("invalid input manifest entry")
        name = relative_name(row.get("path"))
        size = row.get("bytes")
        if name in result or type(size) is not int or size < 0:
            raise EvidenceError(f"duplicate path or invalid byte count: {name}")
        result[name] = (size, checked_hash(row.get("sha256"), name))
    return result


def unpack_inputs(archive, specs, destination):
    """Validate exact membership before streaming members into a private root."""
    with zipfile.ZipFile(archive) as bundle:
        members = bundle.infolist()
        names = [relative_name(member.filename) for member in members]
        if len(set(names)) != len(names) or set(names) != set(specs):
            raise EvidenceError("ZIP inventory differs from input manifest (missing, extra or duplicate member)")
        for member in members:
            size, _ = specs[member.filename]
            kind = stat.S_IFMT(member.external_attr >> 16)
            if member.is_dir() or kind not in (0, stat.S_IFREG) or member.flag_bits & 1:
                raise EvidenceError(f"ZIP member is not an unencrypted regular file: {member.filename}")
            if member.file_size != size:
                raise EvidenceError(f"ZIP byte count mismatch: {member.filename}")
        for member in members:
            size, expected = specs[member.filename]
            path = destination / member.filename
            path.parent.mkdir(parents=True, exist_ok=True)
            value, copied = hashlib.sha256(), 0
            with bundle.open(member) as source, path.open("xb") as target:
                while chunk := source.read(1 << 20):
                    copied += len(chunk)
                    if copied > size:
                        raise EvidenceError(f"ZIP member exceeds declared size: {member.filename}")
                    value.update(chunk)
                    target.write(chunk)
            if copied != size or value.hexdigest() != expected:
                raise EvidenceError(f"input SHA-256 or byte count mismatch: {member.filename}")


def read_packets(root, specs, sdk_base):
    if not isinstance(sdk_base, str) or not re.fullmatch(r"[0-9a-f]{7,40}", sdk_base):
        raise EvidenceError("invalid probe SDK base revision")
    models = sorted(name.removesuffix("/receipt.json") for name in specs if name.endswith("/receipt.json"))
    if not models or any("/" in model for model in models):
        raise EvidenceError("expected one receipt per top-level model directory")
    packets, provenance, consumed = [], {}, set()
    for model in models:
        receipt_name, manifest_name = f"{model}/receipt.json", f"{model}/model-manifest.json"
        if manifest_name not in specs:
            raise EvidenceError(f"missing model manifest: {model}")
        receipt, manifest = load_json(root / receipt_name), load_json(root / manifest_name)
        if not isinstance(receipt, dict) or not isinstance(manifest, dict):
            raise EvidenceError(f"invalid receipt/model manifest: {model}")
        aggregate = checked_hash(receipt.get("model_aggregate_sha256"), model)
        if aggregate != manifest.get("aggregate_sha256"):
            raise EvidenceError(f"receipt/model aggregate mismatch: {model}")
        config_hash = checked_hash(receipt.get("config_sha256"), f"{model} config")
        files = manifest.get("files")
        if not isinstance(files, list):
            raise EvidenceError(f"invalid model file inventory: {model}")
        config_entries = [row for row in files if isinstance(row, dict) and row.get("path") == "config.json"]
        if len(config_entries) != 1 or config_entries[0].get("sha256") != config_hash:
            raise EvidenceError(f"receipt/model config mismatch: {model}")
        revision = receipt.get("sdk_revision")
        if not isinstance(revision, str):
            raise EvidenceError(f"invalid receipt SDK revision: {model}")
        revision = revision.removesuffix("-dirty")
        if len(revision) < 7 or not sdk_base.startswith(revision):
            raise EvidenceError(f"receipt SDK revision mismatch: {model}")
        records = receipt.get("records")
        if not isinstance(records, list) or not records:
            raise EvidenceError(f"missing native records: {model}")
        consumed.update((receipt_name, manifest_name))
        record_names, total, gamma_count = set(), 0, 0
        for row in records:
            if not isinstance(row, dict):
                raise EvidenceError(f"invalid native record: {model}")
            name = f"{model}/{relative_name(row.get('file'))}"
            if name in record_names or name not in specs:
                raise EvidenceError(f"missing or duplicate native record: {name}")
            record_names.add(name)
            size, expected = specs[name]
            if type(row.get("bytes")) is not int or row["bytes"] != size or row.get("sha256") != expected:
                raise EvidenceError(f"receipt/input mismatch: {name}")
            shape, width = row.get("shape"), WIDTHS.get(row.get("dtype"))
            if (not isinstance(shape, list) or not shape or not width
                    or any(type(d) is not int or d <= 0 for d in shape)
                    or math.prod(shape) * width != size
                    or type(row.get("layer")) is not int or row["layer"] < 0
                    or row.get("phase") not in ("prefill", "decode")
                    or type(row.get("position")) is not int or row["position"] <= 0
                    or row.get("role") not in ("keys", "values", "gamma")):
                raise EvidenceError(f"invalid native tensor geometry: {name}")
            total += size
            if row["role"] == "gamma":
                gamma_count += 1
            else:
                packets.append(Packet(model, row, aggregate))
        if receipt.get("copied_native_payload_bytes") != total:
            raise EvidenceError(f"receipt native payload total mismatch: {model}")
        consumed.update(record_names)
        provenance[model] = {
            "receiptSHA256": specs[receipt_name][1], "modelManifestSHA256": specs[manifest_name][1],
            "modelAggregateSHA256": aggregate, "verifiedNativeRecords": len(records),
            "verifiedGammaRecords": gamma_count,
        }
    if consumed != set(specs):
        raise EvidenceError("input manifest contains files not covered by model receipts")
    return packets, provenance


def validate_probe(result, packet):
    row = packet.record
    native, encoded = result.get("nativeBytes"), result.get("encodedFrameBytes")
    if (result.get("schema") != PROBE_SCHEMA or result.get("bitExact") is not True
            or result.get("input") != Path(row["file"]).name
            or result.get("inputSHA256") != row["sha256"]
            or result.get("elementBytes") != WIDTHS[row["dtype"]]
            or type(native) is not int or native != row["bytes"]
            or type(encoded) is not int or encoded <= 0
            or encoded > native + 2 * ((native + (4 << 20) - 1) // (4 << 20))):
        raise EvidenceError(f"invalid codec receipt: {packet.model}/{row['file']}")
    saving = result.get("savingFraction")
    if type(saving) not in (int, float) or not math.isfinite(saving) or abs(saving - (1 - encoded / native)) > 1e-12:
        raise EvidenceError("codec receipt has inconsistent saving fraction")
    for key in ("encodeSeconds", "decodeSeconds"):
        values = result.get(key)
        if (not isinstance(values, list) or len(values) != 5
                or any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in values)):
            raise EvidenceError(f"codec receipt has invalid {key}")


def verify_probe_package(path, expected):
    with zipfile.ZipFile(path) as bundle:
        members = bundle.infolist()
        if len(members) != 1 or members[0].filename != "package.diff" or members[0].file_size > 1 << 20:
            raise EvidenceError("unexpected native probe package-diff ZIP inventory")
        member = members[0]
        if stat.S_IFMT(member.external_attr >> 16) not in (0, stat.S_IFREG) or member.flag_bits & 1:
            raise EvidenceError("native probe package diff is not an unencrypted regular file")
        if hashlib.sha256(bundle.read(member)).hexdigest() != checked_hash(expected, "probe package diff"):
            raise EvidenceError("native probe package diff SHA-256 mismatch")


def run_compiler(command, timeout, cwd=None):
    # Swift's driver spawns compiler/linker children. A deadline must terminate
    # their whole process group before the private build directory is dropped.
    with subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as process:
        try:
            output, errors = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            output, errors = process.communicate()
            raise subprocess.TimeoutExpired(command, timeout, output=output, stderr=errors) from error
        if process.returncode:
            raise subprocess.CalledProcessError(process.returncode, command, output=output, stderr=errors)
        return output


def prepare_codec(args, manifest, driver_bytes, build_root):
    """Use the pinned binary or compile only verified source with fixed options."""
    source_hash = checked_hash(manifest.get("codecSourceSHA256"), "codec source")
    if hashlib.sha256(driver_bytes).hexdigest() != checked_hash(manifest.get("driverSHA256"), "codec driver"):
        raise EvidenceError("codec driver SHA-256 mismatch")
    if bool(args.codec_binary) == bool(args.build_codec_source):
        raise EvidenceError("select exactly one codec binary or verified-source build")
    if args.codec_binary:
        codec = args.codec_binary.resolve()
        expected = checked_hash(manifest.get("binarySHA256"), "codec binary")
        if not codec.is_file() or not os.access(codec, os.X_OK) or digest(codec) != expected:
            raise EvidenceError("codec binary is missing, not executable, or has the wrong SHA-256")
        if args.codec_source and digest(args.codec_source) != source_hash:
            raise EvidenceError("production codec source SHA-256 mismatch")
        return codec, dict(mode="archived-binary", binarySHA256=expected,
                           sourceVerified=args.codec_source is not None, compiler=None)
    if args.codec_source:
        raise EvidenceError("--codec-source applies only to archived-binary mode")
    source_bytes = args.build_codec_source.read_bytes()
    if hashlib.sha256(source_bytes).hexdigest() != source_hash:
        raise EvidenceError("production codec source SHA-256 mismatch")
    if not math.isfinite(args.build_timeout) or args.build_timeout <= 0:
        raise EvidenceError("build timeout must be finite and positive")
    build_root.mkdir()
    # The compiler reads the exact verified bytes, independent of later edits
    # or the caller's original source paths. The enclosing private temp expires.
    (build_root / "SSDLosslessChunkCodec.swift").write_bytes(source_bytes)
    (build_root / "main.swift").write_bytes(driver_bytes)
    compiler = "/usr/bin/swiftc"
    flags = ["-O", "SSDLosslessChunkCodec.swift", "main.swift", "-o", "codec-probe"]
    try:
        version = run_compiler([compiler, "--version"], timeout=10)
        run_compiler([compiler] + flags, cwd=build_root, timeout=args.build_timeout)
    except (subprocess.SubprocessError, OSError) as error:
        detail = getattr(error, "stderr", "") or ""
        if isinstance(detail, bytes):
            detail = detail.decode(errors="replace")
        raise EvidenceError(f"verified codec build failed: {error}; {detail[:2000]}") from error
    codec = build_root / "codec-probe"
    if not codec.is_file() or not os.access(codec, os.X_OK) or not version.strip():
        raise EvidenceError("compiler produced no executable or version provenance")
    return codec, dict(mode="verified-source-build", binarySHA256=digest(codec), sourceVerified=True,
        compiler=dict(path=compiler, invocationExecutableSHA256=digest(compiler), version=version.strip(),
                      versionOutputSHA256=hashlib.sha256(version.encode()).hexdigest(),
                      arguments=flags, buildTimeoutSeconds=args.build_timeout))


def replay(args):
    evidence = Path(__file__).resolve().parent
    archive, output = (path.resolve() for path in (args.input_archive, args.output))
    if args.output.exists() or args.output.is_symlink():
        raise EvidenceError("output directory must not already exist; frozen evidence cannot be overwritten")
    codec_manifest_bytes = args.codec_manifest.read_bytes()
    manifest = parse_json(codec_manifest_bytes, str(args.codec_manifest))
    if not isinstance(manifest, dict):
        raise EvidenceError("invalid codec manifest")
    archived_binary_hash = checked_hash(manifest.get("binarySHA256"), "archived codec binary")
    archive_hash = digest(archive)
    if archive_hash != checked_hash(manifest.get("inputArchiveSHA256"), "input archive"):
        raise EvidenceError("input archive SHA-256 mismatch")
    source_hash = checked_hash(manifest.get("codecSourceSHA256"), "codec source")
    driver_bytes = (evidence / "main.swift").read_bytes()
    probe_hashes = manifest.get("probeSources")
    if not isinstance(probe_hashes, dict) or not probe_hashes:
        raise EvidenceError("missing native probe source hashes")
    for name, expected in probe_hashes.items():
        if digest(evidence / "original-probe" / relative_name(name)) != checked_hash(expected, name):
            raise EvidenceError(f"native probe source SHA-256 mismatch: {name}")
    probe_archive = evidence / "original-probe/package-diff.zip"
    verify_probe_package(probe_archive, manifest.get("probePackageDiffSHA256"))
    input_manifest_bytes = args.input_manifest.read_bytes()
    specs = input_specs(parse_json(input_manifest_bytes, str(args.input_manifest)))
    frozen_summary_bytes = (evidence / "summary.json").read_bytes()
    frozen_results_hash = digest(evidence / "results.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="native-kv-replay-") as temporary:
        root = Path(temporary)
        unpack_inputs(archive, specs, root)
        packets, receipt_provenance = read_packets(root, specs, manifest["probeSDKBase"])
        codec, codec_provenance = prepare_codec(args, manifest, driver_bytes, root / "codec-build")
        results = []
        for packet in packets:
            row = packet.record
            try:
                completed = subprocess.run([str(codec), str(root / packet.model / row["file"]), str(WIDTHS[row["dtype"]])],
                    capture_output=True, text=True, check=True, timeout=args.timeout)
            except (subprocess.SubprocessError, OSError) as error:
                raise EvidenceError(f"codec failed for {packet.model}/{row['file']}: {error}") from error
            result = parse_json(completed.stdout, "codec stdout")
            if not isinstance(result, dict):
                raise EvidenceError("codec receipt must be an object")
            validate_probe(result, packet)
            results.append(dict(result, model=packet.model, phase=row["phase"], layer=row["layer"],
                role=row["role"], dtype=row["dtype"], shape=row["shape"], modelAggregateSHA256=packet.aggregate_hash))
        if digest(codec) != codec_provenance["binarySHA256"]:
            raise EvidenceError("codec binary changed during replay")
    summary = []
    for model in sorted(receipt_provenance):
        rows = [row for row in results if row["model"] == model]
        native, encoded = sum(row["nativeBytes"] for row in rows), sum(row["encodedFrameBytes"] for row in rows)
        if not rows or native <= 0:
            raise EvidenceError(f"no K/V packets: {model}")
        summary.append(dict(model=model, packets=len(rows), nativeBytes=native, encodedFrameBytes=encoded,
            savingFraction=1 - encoded / native, allBitExact=True))
    if summary != parse_json(frozen_summary_bytes, "frozen summary"):
        raise EvidenceError("replayed byte totals differ from the frozen summary")
    if digest(archive) != archive_hash:
        raise EvidenceError("input archive changed during replay")
    provenance = dict(schema="darkbloom.native-kv-lossless-replay.v1", runnerSHA256=digest(__file__),
        inputArchiveSHA256=archive_hash, inputManifestSHA256=hashlib.sha256(input_manifest_bytes).hexdigest(),
        codecManifestSHA256=hashlib.sha256(codec_manifest_bytes).hexdigest(),
        codecBinarySHA256=codec_provenance["binarySHA256"], archivedCodecBinarySHA256=archived_binary_hash,
        codecMode=codec_provenance["mode"], compiler=codec_provenance["compiler"],
        codecSourceSHA256=source_hash, codecSourceVerified=codec_provenance["sourceVerified"],
        driverSHA256=manifest["driverSHA256"], probeSources=probe_hashes,
        probeSDKBase=manifest["probeSDKBase"], probePackageDiffSHA256=manifest["probePackageDiffSHA256"],
        probePackageArchiveSHA256=digest(probe_archive), originalRunnerSHA256=digest(evidence / "original-run.py"),
        models=receipt_provenance, verifiedArchiveMembers=len(specs), measuredKVPackets=len(results),
        frozenResultsSHA256=frozen_results_hash, frozenSummarySHA256=hashlib.sha256(frozen_summary_bytes).hexdigest(),
        scope="All archive members verified, including gamma; only K/V replayed. Fresh CPU timings, no model/GPU run or encrypted SSD qualification.")
    documents = {name: (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()
                 for name, value in (("results.json", results), ("summary.json", summary))}
    provenance.update({name.removesuffix(".json") + "SHA256": hashlib.sha256(data).hexdigest()
                       for name, data in documents.items()})
    documents["provenance.json"] = (json.dumps(provenance, indent=2, sort_keys=True) + "\n").encode()
    with tempfile.TemporaryDirectory(prefix=".native-kv-publish-", dir=output.parent) as temporary:
        staged = Path(temporary) / "result"
        staged.mkdir()
        for name, data in documents.items():
            (staged / name).write_bytes(data)
        if output.exists() or output.is_symlink():
            raise EvidenceError("output appeared during replay; refusing to overwrite it")
        staged.rename(output)
    return summary


def main():
    evidence = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    codec_options = parser.add_mutually_exclusive_group(required=True)
    codec_options.add_argument("--codec-binary", type=Path, help="exact archived binary; its SHA-256 must match")
    codec_options.add_argument("--build-codec-source", type=Path,
                               help="verify and build this production source with fixed /usr/bin/swiftc -O")
    parser.add_argument("--input-archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--input-manifest", type=Path, default=evidence / "input-manifest.json")
    parser.add_argument("--codec-manifest", type=Path, default=evidence / "codec-manifest.json")
    parser.add_argument("--codec-source", type=Path, help="also verify the supplied production Swift source")
    parser.add_argument("--timeout", type=float, default=30, help="per-packet codec timeout in seconds")
    parser.add_argument("--build-timeout", type=float, default=60, help="compiler timeout in seconds")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    if not math.isfinite(args.build_timeout) or args.build_timeout <= 0:
        parser.error("--build-timeout must be finite and positive")
    if args.build_codec_source and args.codec_source:
        parser.error("--codec-source applies only to --codec-binary; build mode verifies its own source")
    try:
        print(json.dumps(replay(args), indent=2, sort_keys=True))
    except (EvidenceError, OSError, zipfile.BadZipFile, zlib.error, NotImplementedError,
            KeyError, TypeError, AttributeError) as error:
        print(f"replay failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
