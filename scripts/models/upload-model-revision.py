#!/usr/bin/env python3
"""Verify a model directory against a canonical manifest, then reserve and upload it (manifest last).

  upload-model-revision.py inputs --model-id ID --version V --template-url URL --source-url URL --recipe R
                                  --manifest FILE [--mode check|build|upload] [--confirm-version V]
  upload-model-revision.py verify --manifest FILE --directory DIR
  upload-model-revision.py upload --manifest FILE --directory DIR --endpoint URL [--bucket darkbloom-models]

- inputs: validates workflow inputs before any secret is in scope: URL shapes (the template a models.darkbloom.ai
  revision under the model's own canonical prefix, the source pinned to a 40-hex Hugging Face commit), the recipe, the
  whole manifest (manifest_problems: what Register and every provider read), its model id, version and canonical
  r2_prefix, and for an upload that the operator repeated the version.
- verify: the manifest again, then the directory holds exactly the manifest's files, each with its size and sha256. A
  rebuild that differs by one byte fails here, before any write.
- upload: publish-model-revision.py's conditional reservation (an existing revision with other bytes is refused), then
  every file, then the manifest as the publication boundary. Never registers or promotes: that stays
  `Register Model` with `publish_revision_only` and `promote`, on the owner's go.
"""
import argparse, datetime, hashlib, importlib.util, json, os, re, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RECIPES = {"g32", "mixed46", "router8", "router8+mixed46"}
CDN = "https://models.darkbloom.ai/"
TEMPLATE_URL = re.compile(r"https://models\.darkbloom\.ai/(v2/[A-Za-z0-9._-]+--[0-9a-f]{12}/[A-Za-z0-9._-]+)/?")
SHA256_HEX = re.compile(r"[0-9a-f]{64}")
# darkbloom-publish hash writes created_at with JSONEncoder's .iso8601: whole seconds and a zone. Providers decode it
# with .iso8601 (ModelCatalogClient.manifestDecoder); older Foundation refuses fractional seconds, so they are refused.
CREATED_AT = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})")
INT64_MAX = 2**63 - 1


def slug_prefix(model_id, version):
    """The canonical r2_prefix, as the coordinator's ModelR2Prefix / readableModelSlug build it:
    v2/<model id, each character outside [0-9A-Za-z._-] as '-', trimmed of '-'>--<sha256(model_id)[:12]>/<version>."""
    readable = "".join(c if re.fullmatch(r"[0-9A-Za-z._-]", c) else "-" for c in model_id).strip("-") or "model"
    return f"v2/{readable}--{hashlib.sha256(model_id.encode()).hexdigest()[:12]}/{version}"


def role_for(filename):
    """ModelScanner.roleFor: the role darkbloom-publish hash records for a file name (the prompt contract hashes the
    tokenizer, template and config roles)."""
    if filename.endswith((".safetensors", ".npz", ".bin")) or filename == "weights.npz":
        return "weight"
    if filename == "model.safetensors.index.json":
        return "index"
    if filename in ("tokenizer.json", "tokenizer_config.json", "tokenizer.model", "special_tokens_map.json",
                    "added_tokens.json", "vocab.json", "merges.txt"):
        return "tokenizer"
    if filename in ("config.json", "hadamard.json", "generation_config.json", "quantize_config.json"):
        return "config"
    if filename in ("chat_template.jinja", "chat_template.json"):
        return "template"
    if filename in ("preprocessor_config.json", "processor_config.json", "video_preprocessor_config.json"):
        return "preprocessor"
    return "other"


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def path_problem(path):
    """The provider's validatedManifestRelativePath and validateArtifactManifest (no hidden part), plus no control
    characters; Register's validManifestRelativePath is weaker."""
    if not isinstance(path, str) or not path:
        return "is empty or not a string"
    if path.startswith("/") or "\\" in path:
        return "is absolute or has a backslash"
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in path):
        return "has a control character"
    for part in path.split("/"):
        if part in ("", ".", "..") or part.startswith("."):
            return "has an empty, '.', '..' or hidden part"
    return None


def manifest_problems(m):
    """What Register (the coordinator's ValidateModelManifest) and every provider (Manifest.swift's decoder, whose
    fields are all required; validateArtifactManifest; ModelScanner.roleFor) need, so an uploaded revision is one
    Register can promote and the fleet can read. A manifest Register accepts but providers can't decode (no
    created_at) would otherwise be promoted, and no provider could converge on it."""
    if not isinstance(m, dict):
        return ["the manifest is not a JSON object"]
    problems = []
    if not is_int(m.get("schema_version")) or m["schema_version"] != 1:
        problems.append("schema_version must be the integer 1")
    for key in ("model_id", "version", "r2_prefix"):
        if not isinstance(m.get(key), str) or not m[key]:
            problems.append(f"{key} must be a non-empty string")
    aggregate = m.get("aggregate_sha256")
    if not isinstance(aggregate, str) or not SHA256_HEX.fullmatch(aggregate):
        problems.append("aggregate_sha256 must be 64 lowercase hex characters")
    created = m.get("created_at")
    if not isinstance(created, str) or not CREATED_AT.fullmatch(created):
        problems.append("created_at must be darkbloom-publish's ISO 8601 form, YYYY-MM-DDTHH:MM:SSZ")
    else:
        try:
            datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))
        except ValueError:
            problems.append("created_at is not a calendar date and time")
    files = m.get("files")
    if not isinstance(files, list) or not files:
        return problems + ["files must be a non-empty list"]
    if not is_int(m.get("file_count")) or m["file_count"] != len(files):
        problems.append("file_count is not the number of files")
    total, seen, hashes_ok = 0, set(), True
    for f in files:
        if not isinstance(f, dict):
            problems.append("a file entry is not an object")
            hashes_ok = False
            continue
        path = f.get("path")
        bad = path_problem(path)
        if bad:
            problems.append(f"file path {path!r} {bad}")
            hashes_ok = False
            continue
        if path.lower() in seen:
            problems.append(f"file path {path!r} is duplicated (case-insensitively)")
        seen.add(path.lower())
        size = f.get("size_bytes")
        if is_int(size) and 0 <= size <= INT64_MAX:
            total += size
        else:
            problems.append(f"{path}: size_bytes must be a non-negative 64-bit integer")
        if not isinstance(f.get("sha256"), str) or not SHA256_HEX.fullmatch(f["sha256"]):
            problems.append(f"{path}: sha256 must be 64 lowercase hex characters")
            hashes_ok = False
        role = role_for(path.rsplit("/", 1)[-1])
        if f.get("role") != role:
            problems.append(f"{path}: role {f.get('role')!r} is not the scanner's {role!r}")
    if not is_int(m.get("total_size_bytes")) or m["total_size_bytes"] != total:
        problems.append("total_size_bytes is not the sum of the file sizes")
    if hashes_ok and isinstance(aggregate, str) and SHA256_HEX.fullmatch(aggregate):
        ordered = sorted(files, key=lambda f: f["path"].encode())
        if hashlib.sha256(b"".join(bytes.fromhex(f["sha256"]) for f in ordered)).hexdigest() != aggregate:
            problems.append("aggregate_sha256 is not the sha256 of the file digests in path order")
    return problems


def load_manifest(path):
    try:
        manifest = json.loads(Path(path).read_text())
    except (OSError, ValueError) as e:
        die(f"the manifest is not readable JSON ({type(e).__name__})")
    problems = manifest_problems(manifest)
    if problems:
        die("manifest: " + "; ".join(problems[:6]) + (f"; and {len(problems) - 6} more" if len(problems) > 6 else ""))
    return manifest


def die(msg):
    print(f"refused: {msg}", file=sys.stderr)
    sys.exit(2)


def cmd_inputs(a):
    manifest = load_manifest(a.manifest)
    if not re.fullmatch(r"[A-Za-z0-9._/-]{1,200}", a.model_id) or ".." in a.model_id:
        die("model_id")
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}", a.version):
        die("version must be one path component, not starting with '.'")
    if a.recipe not in RECIPES:
        die(f"recipe must be one of {sorted(RECIPES)}")
    if not re.fullmatch(r"https://huggingface\.co/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/resolve/[0-9a-f]{40}", a.source_url):
        die("source_url must be https://huggingface.co/<owner>/<repo>/resolve/<40-hex commit>")
    template = TEMPLATE_URL.fullmatch(a.template_url)
    if not template or template.group(1).rsplit("/", 1)[1] in (".", ".."):
        die("template_url must be https://models.darkbloom.ai/v2/<slug>--<12 hex>/<version>")
    template_prefix = template.group(1)
    if template_prefix.rsplit("/", 1)[0] != slug_prefix(a.model_id, "x").rsplit("/", 1)[0]:
        die("template_url is not a revision of this model id")
    if manifest.get("model_id") != a.model_id or manifest.get("version") != a.version:
        die("manifest model_id / version differ from the inputs")
    if manifest.get("r2_prefix") != slug_prefix(a.model_id, a.version):
        die(f"manifest r2_prefix is not the canonical {slug_prefix(a.model_id, a.version)}")
    if template_prefix == manifest["r2_prefix"]:
        die("the new version must differ from the template's")
    if a.mode == "upload" and a.confirm_version != a.version:
        die("upload needs confirm_version equal to version")
    print(f"inputs ok: {a.model_id} {a.version} recipe {a.recipe}; {len(manifest['files'])} files, "
          f"{manifest.get('total_size_bytes', 0) / 1e9:.2f} GB, aggregate {manifest.get('aggregate_sha256', '')[:16]}…; "
          f"template prefix {template_prefix}")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"template_manifest_key={template_prefix}/manifest.json\n")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_verify(a):
    manifest = load_manifest(a.manifest)
    d = Path(a.directory)
    want = {f["path"]: f for f in manifest["files"]}
    have = {str(p.relative_to(d)) for p in d.rglob("*") if p.is_file()}
    bad = []
    if have != set(want):
        bad.append(f"file set differs: missing {sorted(set(want) - have)}, extra {sorted(have - set(want))}")
    for rel in sorted(set(want) & have):
        f, p = want[rel], d / rel
        size = p.stat().st_size
        if size != f.get("size_bytes"):
            bad.append(f"{rel}: size {size} != {f.get('size_bytes')}")
            continue
        got = sha256(p)
        print(f"{rel}: {'ok' if got == f['sha256'] else 'SHA256 DIFFERS'}", flush=True)
        if got != f["sha256"]:
            bad.append(f"{rel}: sha256 {got} != {f['sha256']}")
    if bad:
        die("; ".join(bad))
    print(f"verified: {len(want)} files match the manifest byte for byte")


def cmd_upload(a):
    spec = importlib.util.spec_from_file_location("pmr", ROOT / "scripts" / "publish-model-revision.py")
    pmr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pmr)
    cmd_verify(a)
    manifest_path = Path(a.manifest).resolve()
    manifest = json.loads(manifest_path.read_text())
    with tempfile.TemporaryDirectory(prefix="model-upload-") as scratch:
        if pmr.reserve_revision(manifest, a.bucket, a.endpoint, scratch):
            pmr.publish_files(Path(a.directory), manifest_path, manifest, a.bucket, a.endpoint)
            print(f"uploaded {manifest['r2_prefix']} (manifest last); not registered, not promoted")
        else:
            print(f"{manifest['r2_prefix']} was already published with these bytes; nothing uploaded")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("inputs")
    for k in ("--model-id", "--version", "--template-url", "--source-url", "--recipe", "--manifest"):
        p.add_argument(k, required=True)
    p.add_argument("--mode", default="check")
    p.add_argument("--confirm-version", default="")
    for name in ("verify", "upload"):
        q = sub.add_parser(name)
        q.add_argument("--manifest", required=True)
        q.add_argument("--directory", required=True)
        if name == "upload":
            q.add_argument("--endpoint", required=True)
            q.add_argument("--bucket", default="darkbloom-models")
    a = ap.parse_args()
    {"inputs": cmd_inputs, "verify": cmd_verify, "upload": cmd_upload}[a.cmd](a)


if __name__ == "__main__":
    main()
