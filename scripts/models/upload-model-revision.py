#!/usr/bin/env python3
"""Verify a model directory against a canonical manifest, then reserve and upload it (manifest last).

  upload-model-revision.py inputs --model-id ID --version V --template-url URL --source-url URL --recipe R
                                  --manifest FILE [--mode check|build|upload] [--confirm-version V]
  upload-model-revision.py verify --manifest FILE --directory DIR
  upload-model-revision.py upload --manifest FILE --directory DIR --endpoint URL [--bucket darkbloom-models]

- inputs: validates workflow inputs before any secret is in scope: URL shapes (the template on models.darkbloom.ai under
  the model's own canonical prefix, the source pinned to a 40-hex Hugging Face commit), the recipe, the manifest's model
  id, version and canonical r2_prefix, and for an upload that the operator repeated the version.
- verify: the directory holds exactly the manifest's files, each with its size and sha256. A rebuild that differs by
  one byte fails here, before any write.
- upload: publish-model-revision.py's conditional reservation (an existing revision with other bytes is refused), then
  every file, then the manifest as the publication boundary. Never registers or promotes: that stays
  `Register Model` with `publish_revision_only` and `promote`, on the owner's go.
"""
import argparse, hashlib, importlib.util, json, os, re, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RECIPES = {"g32", "mixed46", "router8", "router8+mixed46"}
CDN = "https://models.darkbloom.ai/"


def slug_prefix(model_id, version):
    """The canonical r2_prefix, as the coordinator's ModelR2Prefix / readableModelSlug build it:
    v2/<model id, each character outside [0-9A-Za-z._-] as '-', trimmed of '-'>--<sha256(model_id)[:12]>/<version>."""
    readable = "".join(c if re.fullmatch(r"[0-9A-Za-z._-]", c) else "-" for c in model_id).strip("-") or "model"
    return f"v2/{readable}--{hashlib.sha256(model_id.encode()).hexdigest()[:12]}/{version}"


def die(msg):
    print(f"refused: {msg}", file=sys.stderr)
    sys.exit(2)


def cmd_inputs(a):
    manifest = json.loads(Path(a.manifest).read_text())
    if not re.fullmatch(r"[A-Za-z0-9._/-]{1,200}", a.model_id) or ".." in a.model_id:
        die("model_id")
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", a.version):
        die("version must be one path component")
    if a.recipe not in RECIPES:
        die(f"recipe must be one of {sorted(RECIPES)}")
    if not re.fullmatch(r"https://huggingface\.co/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/resolve/[0-9a-f]{40}", a.source_url):
        die("source_url must be https://huggingface.co/<owner>/<repo>/resolve/<40-hex commit>")
    if not a.template_url.startswith(CDN + "v2/") or ".." in a.template_url:
        die("template_url must be a models.darkbloom.ai/v2/ revision")
    template_prefix = a.template_url[len(CDN):].rstrip("/")
    if template_prefix.rsplit("/", 1)[0] != slug_prefix(a.model_id, "x").rsplit("/", 1)[0]:
        die("template_url is not a revision of this model id")
    if manifest.get("model_id") != a.model_id or manifest.get("version") != a.version:
        die("manifest model_id / version differ from the inputs")
    if manifest.get("r2_prefix") != slug_prefix(a.model_id, a.version):
        die(f"manifest r2_prefix is not the canonical {slug_prefix(a.model_id, a.version)}")
    if template_prefix == manifest["r2_prefix"]:
        die("the new version must differ from the template's")
    for f in manifest.get("files", []):
        p = Path(f["path"])
        if p.is_absolute() or ".." in p.parts or not re.fullmatch(r"[0-9a-f]{64}", f.get("sha256", "")):
            die(f"manifest entry {f.get('path')!r}")
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
    manifest = json.loads(Path(a.manifest).read_text())
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
