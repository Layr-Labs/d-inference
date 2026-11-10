"""Model Requant Upload: input and manifest validation, the workflow's steps run as the runner runs them (a fake `aws`
and `python3`, no network, no credentials), the hash-pinned tools, the range reader, and the quantizer's packing,
self-test and float64 oracle (numpy only where present)."""
import contextlib
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
WORKFLOW = ROOT / ".github/workflows/model-requant-upload.yml"
UPLOAD = HERE / "upload-model-revision.py"
REQUANT = HERE / "requant.py"
REQUIREMENTS = HERE / "requirements-requant-upload.txt"
# The published Qwen3.5-9B revision's manifest (models.darkbloom.ai, read 2026-11-10), as `darkbloom-publish hash`
# wrote it and as Register and every provider read it.
PUBLISHED_MANIFEST = HERE / "testdata/Qwen3.5-9B-2026-09-03-r1.manifest.json"
HAVE_NUMPY = importlib.util.find_spec("numpy") is not None
# A fixture endpoint shaped like R2's (a 32-hex account): its digits must never reach a log.
ENDPOINT = "https://a1279c773e049f2d5b8a6c0e4f1d3b2a.r2.cloudflarestorage.com"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


up = load("upload_model_revision", UPLOAD)
SRC = "https://huggingface.co/Qwen/Qwen3.5-9B/resolve/" + "c" * 40
# ModelScanner.roleFor's roles for the names used here, written out independently of the script under test.
ROLE = {"config.json": "config", "model.safetensors.index.json": "index", "tokenizer.json": "tokenizer",
        "chat_template.jinja": "template", "preprocessor_config.json": "preprocessor",
        "model-00001-of-00001.safetensors": "weight", "mtp/model.safetensors": "weight", "README.md": "other"}


def refresh(manifest):
    """Recompute file_count, total and aggregate (sha256 of the raw digests sorted by path) after editing files."""
    files = manifest["files"]
    manifest["file_count"] = len(files)
    manifest["total_size_bytes"] = sum(f["size_bytes"] for f in files)
    ordered = sorted(files, key=lambda f: f["path"])
    manifest["aggregate_sha256"] = hashlib.sha256(b"".join(bytes.fromhex(f["sha256"]) for f in ordered)).hexdigest()
    return manifest


def manifest_for(model_id, version, files, created_at="2026-11-10T20:30:00Z"):
    entries = [{"path": p, "role": ROLE[p], "sha256": hashlib.sha256(b).hexdigest(), "size_bytes": len(b)}
               for p, b in sorted(files.items())]
    return refresh({"schema_version": 1, "model_id": model_id, "version": version,
                    "r2_prefix": up.slug_prefix(model_id, version), "files": entries, "created_at": created_at})


def run_inputs(manifest, **over):
    with tempfile.TemporaryDirectory() as d:
        mp = Path(d) / "m.json"
        mp.write_text(json.dumps(manifest))
        args = {"--model-id": manifest.get("model_id", "Qwen3.5-9B"), "--version": manifest.get("version", "v"),
                "--template-url": "https://models.darkbloom.ai/" + up.slug_prefix("Qwen3.5-9B", "2026-09-03-r1"),
                "--source-url": SRC, "--recipe": "g32", "--manifest": str(mp), "--mode": "build", "--confirm-version": "",
                "--keys": "prod"}
        args.update(over)
        out = Path(d) / "github_output"
        cmd = [sys.executable, str(UPLOAD), "inputs"] + [x for kv in args.items() for x in kv]
        result = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, "GITHUB_OUTPUT": str(out)})
        result.github_output = out.read_text() if out.exists() else ""
        return result


class CanonicalPrefix(unittest.TestCase):
    def test_matches_published_prefixes(self):
        # Published revisions (models.darkbloom.ai catalog, 2026-11-10).
        for model_id, prefix in {
            "Qwen3.5-9B": "v2/Qwen3.5-9B--3e3c04992a0d/2026-09-03-r1",
            "qwen3.6-35b-a3b-vl-mtp-mxfp8": "v2/qwen3.6-35b-a3b-vl-mtp-mxfp8--943d60189096/2026-08-11-r1",
            "EigenLabs/Qwen3.8-27B-4bit-mtp": "v2/EigenLabs-Qwen3.8-27B-4bit-mtp--96c072dbd610/2026-09-03-r1",
        }.items():
            self.assertEqual(up.slug_prefix(model_id, prefix.rsplit("/", 1)[1]), prefix)


class Inputs(unittest.TestCase):
    def setUp(self):
        self.m = manifest_for("Qwen3.5-9B", "2026-11-12-g32-r1", {
            "config.json": b"{}", "model-00001-of-00001.safetensors": b"x" * 64, "tokenizer.json": b"[]"})

    def test_valid_build(self):
        r = run_inputs(self.m)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.github_output, "template_manifest_key=v2/Qwen3.5-9B--3e3c04992a0d/2026-09-03-r1/manifest.json\n")

    def test_both_key_sets(self):
        for keys in ("prod", "legacy"):
            self.assertEqual(run_inputs(self.m, **{"--keys": keys}).returncode, 0, keys)

    def test_upload_needs_the_version_repeated(self):
        self.assertNotEqual(run_inputs(self.m, **{"--mode": "upload"}).returncode, 0)
        self.assertEqual(run_inputs(self.m, **{"--mode": "upload", "--confirm-version": "2026-11-12-g32-r1"}).returncode, 0)

    def test_refusals(self):
        template = "https://models.darkbloom.ai/" + up.slug_prefix("Qwen3.5-9B", "2026-09-03-r1")
        bad = [
            {"--source-url": "https://huggingface.co/Qwen/Qwen3.5-9B/resolve/main"},
            {"--source-url": "https://evil.example/x"},
            {"--template-url": "https://models.darkbloom.ai/v2/other--000000000000/2026-01-01-r1"},
            {"--template-url": "https://models.darkbloom.ai/" + up.slug_prefix("Qwen3.5-9B", "2026-11-12-g32-r1")},
            # A newline would add a second line to GITHUB_OUTPUT; a query or a deeper path is not a revision.
            {"--template-url": template + "\nmore=1"},
            {"--template-url": template + "?x=1"},
            {"--template-url": template + "/extra"},
            {"--template-url": template.replace("https://", "http://")},
            {"--recipe": "8bit"},
            {"--keys": "both"},
            {"--keys": "PROD"},
            {"--version": "2026-11-12-g32-r2"},
            {"--model-id": "qwen3.5-35b-a3b"},
        ]
        for over in bad:
            r = run_inputs(self.m, **over)
            self.assertNotEqual(r.returncode, 0, over)
            self.assertEqual(r.github_output, "", over)
        wrong_prefix = dict(self.m, r2_prefix="v2/elsewhere/2026-11-12-g32-r1")
        self.assertNotEqual(run_inputs(wrong_prefix).returncode, 0)
        # A consistent manifest for a dot version is still not a new prefix.
        for version in ("..", ".", ".hidden"):
            dotted = manifest_for("Qwen3.5-9B", version, {"config.json": b"{}"})
            self.assertNotEqual(run_inputs(dotted).returncode, 0, version)

    def test_manifest_is_what_register_and_the_providers_read(self):
        """Register (ValidateModelManifest) would refuse these, or worse promote them while every provider fails to
        decode or validate the manifest (Manifest.swift, validateArtifactManifest, ModelScanner.roleFor)."""
        def edit(change, recount=False):
            m = json.loads(json.dumps(self.m))
            change(m)
            return refresh(m) if recount else m

        def file0(**kv):
            return lambda m: m["files"][0].update(kv)

        def add(path, role, body=b"z"):
            return lambda m: m["files"].append(
                {"path": path, "role": role, "sha256": hashlib.sha256(body).hexdigest(), "size_bytes": len(body)})

        cases = {
            "no created_at": edit(lambda m: m.pop("created_at")),
            "created_at without a zone": edit(lambda m: m.update(created_at="2026-11-10T20:30:00")),
            "created_at with a space": edit(lambda m: m.update(created_at="2026-11-10 20:30:00Z")),
            "created_at with fractional seconds": edit(lambda m: m.update(created_at="2026-11-10T20:30:00.123Z")),
            "created_at not a date": edit(lambda m: m.update(created_at="2026-02-30T20:30:00Z")),
            "created_at a number": edit(lambda m: m.update(created_at=1731270600)),
            "no schema_version": edit(lambda m: m.pop("schema_version")),
            "schema_version 2": edit(lambda m: m.update(schema_version=2)),
            "schema_version a string": edit(lambda m: m.update(schema_version="1")),
            "schema_version a bool": edit(lambda m: m.update(schema_version=True)),
            "file_count": edit(lambda m: m.update(file_count=m["file_count"] + 1)),
            "file_count a float": edit(lambda m: m.update(file_count=float(m["file_count"]))),
            "total": edit(lambda m: m.update(total_size_bytes=m["total_size_bytes"] + 1)),
            "aggregate zero": edit(lambda m: m.update(aggregate_sha256="0" * 64)),
            "aggregate upper case": edit(lambda m: m.update(aggregate_sha256=m["aggregate_sha256"].upper())),
            "no files": edit(lambda m: m.update(files=[]), recount=True),
            "duplicate path, other case": edit(add("Config.json", "other"), recount=True),
            "no role": edit(lambda m: m["files"][0].pop("role"), recount=True),
            "role not the scanner's": edit(file0(role="other"), recount=True),
            "sha256 upper case": edit(lambda m: m["files"][0].update(sha256=m["files"][0]["sha256"].upper()),
                                      recount=True),
            "size negative": edit(file0(size_bytes=-1), recount=True),
            "size a float": edit(file0(size_bytes=2.0), recount=True),
            "size a bool": edit(file0(size_bytes=True), recount=True),
            "hidden component": edit(add(".cache/x.json", "other"), recount=True),
            "backslash": edit(add("a\\b.json", "other"), recount=True),
            "empty segment": edit(add("a//b.json", "other"), recount=True),
            "dot segment": edit(add("./b.json", "other"), recount=True),
            "parent segment": edit(add("../b.json", "other"), recount=True),
            "absolute": edit(add("/b.json", "other"), recount=True),
            "control character": edit(add("b\n.json", "other"), recount=True),
        }
        for name, manifest in cases.items():
            with self.subTest(name):
                self.assertNotEqual(run_inputs(manifest).returncode, 0, name)

    def test_a_published_manifest_passes(self):
        self.assertEqual(up.manifest_problems(json.loads(PUBLISHED_MANIFEST.read_text())), [])


class Verify(unittest.TestCase):
    def run_verify(self, manifest, directory, d):
        mp = Path(d) / "m.json"
        mp.write_text(json.dumps(manifest))
        return subprocess.run([sys.executable, str(UPLOAD), "verify", "--manifest", str(mp), "--directory", str(directory)],
                              capture_output=True, text=True)

    def test_exact_files_only(self):
        files = {"config.json": b"{}", "model-00001-of-00001.safetensors": b"x" * 100}
        m = manifest_for("Qwen3.5-9B", "v1", files)
        with tempfile.TemporaryDirectory() as d:
            md = Path(d) / "model"
            md.mkdir()
            for p, b in files.items():
                (md / p).write_bytes(b)
            ok = self.run_verify(m, md, d)
            self.assertEqual(ok.returncode, 0, ok.stderr)
            (md / "model-00001-of-00001.safetensors").write_bytes(b"y" * 100)
            self.assertNotEqual(self.run_verify(m, md, d).returncode, 0)
            (md / "model-00001-of-00001.safetensors").write_bytes(b"x" * 100)
            (md / "extra.txt").write_bytes(b"")
            self.assertNotEqual(self.run_verify(m, md, d).returncode, 0)
            (md / "extra.txt").unlink()
            # Matching bytes do not make an unreadable manifest uploadable (verify gates upload).
            no_date = dict(m)
            no_date.pop("created_at")
            self.assertNotEqual(self.run_verify(no_date, md, d).returncode, 0)


# ---- the workflow's steps, read without a YAML dependency and run as the runner's bash runs them --------------------

def parse_step(lines):
    step, i = {"env": {}}, 0
    while i < len(lines):
        m = re.match(r"^        ([a-z-]+):(?: (.*))?$", lines[i])
        i += 1
        if not m:
            continue
        key, value, nested = m.group(1), m.group(2), []
        while i < len(lines) and (not lines[i].strip() or lines[i].startswith("          ")):
            nested.append(lines[i])
            i += 1
        if key == "run" and value == "|":
            step["run"] = textwrap.dedent("\n".join(nested)).strip("\n") + "\n"
        elif key == "env":
            step["env"] = dict(re.match(r"^\s+([A-Za-z0-9_]+): (.*)$", line).groups() for line in nested if line.strip())
        elif key == "with":
            step["with"] = nested
        else:
            step[key] = value
    return step


def workflow_jobs():
    """{job id: {"fields": {key: value}, "steps": [step, ...]}}, in file order, without a YAML dependency."""
    body = WORKFLOW.read_text().split("\njobs:\n", 1)[1]
    heads = list(re.finditer(r"^  ([A-Za-z0-9_-]+):\n", body, re.MULTILINE))
    out = {}
    for i, head in enumerate(heads):
        lines = body[head.end():heads[i + 1].start() if i + 1 < len(heads) else len(body)].splitlines()
        fields = dict(re.match(r"^    ([a-z-]+):(?: (.*))?$", line).groups() for line in lines
                      if re.match(r"^    [a-z-]+:", line))
        blocks = []
        for line in lines[lines.index("    steps:") + 1:]:
            if line.startswith("      - "):
                blocks.append(["        " + line[len("      - "):]])
            elif blocks and (not line.strip() or line.startswith("        ")):
                blocks[-1].append(line)
            elif line.strip():
                break
        out[head.group(1)] = {"fields": fields, "steps": [parse_step(block) for block in blocks]}
    return out


def uses_secrets(step):
    return any("secrets." in v for v in step["env"].values())


def secret_names(step):
    return {name for v in step["env"].values() for name in re.findall(r"secrets\.([A-Z0-9_]+)", v)}


# A fake aws or python3: logs the call (aws with the key id it got), and an aws call made with $FAKE_BAD_KEY fails
# with $FAKE_STDERR, as a connection or permission error would.
FAKE_TOOL = """#!/bin/sh
echo "$(basename "$0") key=${AWS_ACCESS_KEY_ID:-} $*" >> "$FAKE_LOG"
if [ -n "${FAKE_BAD_KEY:-}" ] && [ "${AWS_ACCESS_KEY_ID:-}" = "$FAKE_BAD_KEY" ]; then
  [ -z "${FAKE_STDERR:-}" ] || printf '%s\\n' "$FAKE_STDERR" >&2
  exit 255
fi
[ -z "${FAKE_STDOUT:-}" ] || printf '%s\\n' "$FAKE_STDOUT"
exit 0
"""
PROD = {"PROD_R2_ACCESS_KEY_ID": "prod-key-id", "PROD_R2_SECRET_ACCESS_KEY": "prod-secret", "PROD_R2_ENDPOINT": ENDPOINT}
LEGACY = {"LEGACY_R2_ACCESS_KEY_ID": "legacy-key-id", "LEGACY_R2_SECRET_ACCESS_KEY": "legacy-secret",
          "LEGACY_R2_ENDPOINT": ENDPOINT}
CHOSEN = {"AWS_ACCESS_KEY_ID": "chosen-key-id", "AWS_SECRET_ACCESS_KEY": "chosen-secret", "R2_ENDPOINT": ENDPOINT}
ALL_R2 = {"PROD_R2_ACCESS_KEY_ID", "PROD_R2_SECRET_ACCESS_KEY", "PROD_R2_ENDPOINT",
          "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_ENDPOINT"}


class WorkflowSteps(unittest.TestCase):
    def setUp(self):
        self.jobs = workflow_jobs()
        self.text = WORKFLOW.read_text()
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.d = Path(scratch.name)
        (self.d / "bin").mkdir()
        for tool in ("aws", "python3"):
            (self.d / "bin" / tool).write_text(FAKE_TOOL)
            (self.d / "bin" / tool).chmod(0o755)
        self.log = self.d / "calls.log"
        self.output = self.d / "github_output"

    def steps(self, job="requant-upload"):
        return self.jobs[job]["steps"]

    def named(self, fragment, job="requant-upload"):
        found = [s for s in self.steps(job) if fragment in (s.get("name") or "")]
        self.assertEqual(len(found), 1, fragment)
        return found[0]

    def run_step(self, step, **env):
        self.log.unlink(missing_ok=True)
        self.output.unlink(missing_ok=True)
        base = {"PATH": f"{self.d / 'bin'}:/usr/bin:/bin", "HOME": str(self.d), "RUNNER_TEMP": str(self.d),
                "GITHUB_OUTPUT": str(self.output), "FAKE_LOG": str(self.log), "MODE": "check", "KEYS": "prod",
                "MODEL_ID": "Qwen3.5-9B", "VERSION": "2026-11-12-g32-r1",
                "KEY": "v2/Qwen3.5-9B--3e3c04992a0d/2026-09-03-r1/manifest.json"}
        base.update(env)
        result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
                                cwd=self.d, env=base, capture_output=True, text=True, timeout=60)
        result.calls = self.log.read_text().splitlines() if self.log.exists() else []
        result.outputs = dict(line.split("=", 1) for line in self.output.read_text().splitlines()) \
            if self.output.exists() else {}
        return result

    def test_secrets_only_in_the_prod_job_after_a_secret_free_preflight(self):
        self.assertEqual(list(self.jobs), ["preflight", "requant-upload"])
        pre, main = self.jobs["preflight"], self.jobs["requant-upload"]
        self.assertNotIn("environment", pre["fields"])
        self.assertFalse(any(uses_secrets(s) for s in pre["steps"]))
        # The prod environment: its required reviewer approves each run, its branch policy admits master; its
        # secrets (PROD_R2_*) are visible only to a job that names it.
        self.assertEqual(main["fields"].get("environment"), "prod")
        self.assertEqual(main["fields"].get("needs"), "preflight")
        names = [s.get("name") or s.get("uses") for s in pre["steps"]]
        for fragment in ("Refuse a run", "actions/checkout@", "Validate inputs", "Install tools by hash", "Self-test"):
            self.assertTrue(any(fragment in n for n in names), fragment)
        self.assertNotIn("${{ secrets", self.text.split("\njobs:\n")[0])

    def test_runs_only_from_master(self):
        for job in self.jobs:
            guard = self.steps(job)[0]
            refs = [k for k, v in guard["env"].items() if v == "${{ github.ref }}"]
            self.assertEqual(len(refs), 1, f"{job}: the first step reads github.ref")
            self.assertFalse(uses_secrets(guard))
            self.assertNotIn("if", guard)
            for ref in ("refs/heads/dev", "refs/heads/master-copy", "refs/heads/x/master", "refs/tags/v0.10.12",
                        "refs/heads/v0.10.12", "refs/pull/1975/merge", ""):
                r = self.run_step(guard, **{refs[0]: ref})
                self.assertNotEqual(r.returncode, 0, ref)
                self.assertIn("::error::", r.stdout, ref)
            self.assertEqual(self.run_step(guard, **{refs[0]: "refs/heads/master"}).returncode, 0)

    def test_only_the_check_and_the_upload_hold_keys(self):
        held = [s["name"].split(" ")[0] for s in self.steps() if uses_secrets(s)]
        self.assertEqual(held, ["Check", "Reserve"])
        self.assertEqual(secret_names(self.named("Check")), ALL_R2)
        self.assertEqual(secret_names(self.named("Reserve")), ALL_R2)

    def test_check_tests_both_key_sets_and_prints_only_pass_or_fail(self):
        check = self.named("Check")
        self.assertEqual(check.get("id"), "check")
        printed = re.compile(r"keys (prod \(PROD_R2_\*\)|legacy \(R2_\*\)): (pass|fail|fail \(not set\))")

        def only_verdicts(r):
            for line in r.stdout.splitlines():
                self.assertTrue(printed.fullmatch(line) or line.startswith("::error::"), line)
            self.assertEqual(r.stderr, "")

        both = self.run_step(check, **PROD, **LEGACY)
        self.assertEqual(both.returncode, 0, both.stdout + both.stderr)
        self.assertEqual(both.outputs, {"prod": "pass", "legacy": "pass"})
        self.assertEqual(sorted(c.split()[1] for c in both.calls), ["key=legacy-key-id", "key=prod-key-id"])
        self.assertTrue(all("head-object --bucket darkbloom-models" in c for c in both.calls), both.calls)
        only_verdicts(both)

        # PROD_R2_* not set (the prod environment had no secrets on 11-10): reported, nothing run with it.
        legacy_only = self.run_step(check, **LEGACY)
        self.assertEqual(legacy_only.returncode, 0)
        self.assertEqual(legacy_only.outputs, {"prod": "fail", "legacy": "pass"})
        self.assertIn("keys prod (PROD_R2_*): fail (not set)", legacy_only.stdout)
        self.assertEqual([c.split()[1] for c in legacy_only.calls], ["key=legacy-key-id"])
        only_verdicts(legacy_only)
        for name in PROD:  # any one missing part of a set fails that set without running anything with it
            partial = self.run_step(check, **{**PROD, name: ""}, **LEGACY)
            self.assertEqual(partial.outputs["prod"], "fail", name)
            self.assertEqual([c.split()[1] for c in partial.calls], ["key=legacy-key-id"], name)

        # A failing set prints no part of aws's error, which names the endpoint.
        leaked = {run[i:i + 3] for run in re.findall(r"\d{3,}", ENDPOINT) for i in range(len(run) - 2)}
        broken = self.run_step(check, **PROD, **LEGACY, FAKE_BAD_KEY="legacy-key-id", FAKE_STDERR=(
            f'Could not connect to the endpoint URL: "{ENDPOINT}/darkbloom-models/x" (403)'))
        self.assertEqual(broken.returncode, 0)
        self.assertEqual(broken.outputs, {"prod": "pass", "legacy": "fail"})
        for fragment in leaked:
            self.assertNotIn(fragment, broken.stdout + broken.stderr, fragment)
        only_verdicts(broken)

        neither = self.run_step(check, **PROD, FAKE_BAD_KEY="prod-key-id")
        self.assertNotEqual(neither.returncode, 0)
        self.assertIn("::error::", neither.stdout)
        self.assertEqual(neither.outputs, {"prod": "fail", "legacy": "fail"})

        # upload: the chosen set must pass here, before an hour of rebuilding.
        self.assertNotEqual(self.run_step(check, **LEGACY, MODE="upload", KEYS="prod").returncode, 0)
        self.assertEqual(self.run_step(check, **LEGACY, MODE="upload", KEYS="legacy").returncode, 0)
        self.assertEqual(self.run_step(check, **PROD, **LEGACY, MODE="upload", KEYS="prod").returncode, 0)

    def test_upload_holds_only_the_chosen_set_and_needs_this_runs_check(self):
        upload = self.named("Reserve")
        for var, (prod, legacy) in {"AWS_ACCESS_KEY_ID": ("PROD_R2_ACCESS_KEY_ID", "R2_ACCESS_KEY_ID"),
                                    "AWS_SECRET_ACCESS_KEY": ("PROD_R2_SECRET_ACCESS_KEY", "R2_SECRET_ACCESS_KEY"),
                                    "R2_ENDPOINT": ("PROD_R2_ENDPOINT", "R2_ENDPOINT")}.items():
            self.assertEqual(upload["env"][var], f"${{{{ inputs.keys == 'prod' && secrets.{prod} || '' }}}}"
                                                 f"${{{{ inputs.keys == 'legacy' && secrets.{legacy} || '' }}}}")
        self.assertEqual(upload["env"]["PROD_CHECK"], "${{ steps.check.outputs.prod }}")
        self.assertEqual(upload["env"]["LEGACY_CHECK"], "${{ steps.check.outputs.legacy }}")
        ok = self.run_step(upload, **CHOSEN, KEYS="prod", PROD_CHECK="pass", LEGACY_CHECK="fail", MODE="upload")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertEqual(len(ok.calls), 1)
        self.assertTrue(ok.calls[0].startswith("python3 "), ok.calls)
        legacy = self.run_step(upload, **CHOSEN, KEYS="legacy", PROD_CHECK="fail", LEGACY_CHECK="pass", MODE="upload")
        self.assertEqual(legacy.returncode, 0, legacy.stdout + legacy.stderr)
        refused = [dict(KEYS="prod", PROD_CHECK="fail", LEGACY_CHECK="pass"),
                   dict(KEYS="legacy", PROD_CHECK="pass", LEGACY_CHECK="fail"),
                   dict(KEYS="prod", LEGACY_CHECK="pass"),
                   dict(KEYS="both", PROD_CHECK="pass", LEGACY_CHECK="pass")]
        for case in refused:
            r = self.run_step(upload, **CHOSEN, **case, MODE="upload")
            self.assertNotEqual(r.returncode, 0, case)
            self.assertIn("::error::", r.stdout, case)
            self.assertEqual(r.calls, [], case)
        for var in CHOSEN:
            r = self.run_step(upload, **{**CHOSEN, var: ""}, KEYS="prod", PROD_CHECK="pass", MODE="upload")
            self.assertNotEqual(r.returncode, 0, var)
            self.assertIn("::error::", r.stdout)
            self.assertEqual(r.calls, [], var)

    def test_keys_input(self):
        m = re.search(r"\n      keys:\n((?:        .*\n)+)", self.text.split("\njobs:\n", 1)[0])
        self.assertIsNotNone(m, "a keys input")
        for line in ("default: prod", "type: choice", "options: [prod, legacy]"):
            self.assertIn(line, m.group(1))
        self.assertIn("  KEYS: ${{ inputs.keys }}\n", self.text)
        self.assertIn('--keys "$KEYS"', self.named("Validate inputs", "preflight")["run"])

    def test_tools_are_pinned_by_hash(self):
        for job in self.jobs:
            installs = [s for s in self.steps(job) if re.search(r"\bpip\b", s.get("run", ""))]
            self.assertEqual(len(installs), 1, job)
            for flag in ("--require-hashes", "--only-binary :all:", "-r scripts/models/requirements-requant-upload.txt"):
                self.assertIn(flag, installs[0]["run"])
        self.assertEqual(len(re.findall(r"\bpip\b.*\binstall\b", self.text)), len(self.jobs))
        logical = re.sub(r"\s*\\\n\s*", " ", REQUIREMENTS.read_text())
        pins = {}
        for line in logical.splitlines():
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            m = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.]+)((?: --hash=sha256:[0-9a-f]{64})+)", line)
            self.assertIsNotNone(m, line[:80])
            pins[m.group(1).lower()] = m.group(2)
        self.assertEqual(pins["numpy"], "2.5.4")
        self.assertEqual(pins["awscli"], "1.46.3")
        self.assertEqual(set(pins), {"awscli", "colorama", "docutils", "jmespath", "pyasn1", "python-dateutil",
                                     "pyyaml", "rsa", "six", "urllib3", "numpy"})

    def test_selftest_runs_in_every_mode_before_any_secret(self):
        for job in self.jobs:
            steps = self.steps(job)
            install = next(i for i, s in enumerate(steps) if re.search(r"\bpip\b", s.get("run", "")))
            selftest = steps[install + 1]
            self.assertIn("python3 scripts/models/requant.py selftest", selftest.get("run", ""), job)
            self.assertIn("sha256sum scripts/models/requant.py", selftest["run"])
            self.assertNotIn("if", selftest)
            first_secret = next((i for i, s in enumerate(steps) if uses_secrets(s)), len(steps))
            self.assertLess(install + 1, first_secret)

    def test_scripts_see_inputs_only_through_env(self):
        self.assertIn("default: check", self.text)
        self.assertIn("permissions:\n  contents: read", self.text)
        self.assertEqual(self.text.count("persist-credentials: false"), len(self.jobs))
        for job in self.jobs:
            for step in self.steps(job):
                self.assertNotIn("${{", step.get("run", ""), step.get("name"))
                for line in step.get("run", "").splitlines():  # promotion appears only as a printed hint
                    if "promot" in line:
                        self.assertTrue(line.lstrip().startswith("echo "), line)
        rebuild = self.named("Rebuild")
        self.assertFalse(uses_secrets(rebuild))
        build = re.search(r"requant\.py build(?:[^\n]*\\\n)*[^\n]*", rebuild["run"]).group(0)
        self.assertNotIn("|", build, "the rebuild's progress streams")
        self.assertNotIn("publish-revision", self.text)


# ---- the range reader -----------------------------------------------------------------------------------------------

@contextlib.contextmanager
def server(responses):
    """Serve `responses` (status, headers, body) in order to GETs, then repeat the last one."""
    seen = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append(self.headers.get("Range"))
            status, headers, body = responses[min(len(seen), len(responses)) - 1]
            self.send_response(status)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=httpd.serve_forever, daemon=True)
    worker.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}/f", seen
    finally:
        httpd.shutdown()
        httpd.server_close()
        worker.join()


@unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
class RangeReads(unittest.TestCase):
    def setUp(self):
        self.rq = load("requant", REQUANT)
        os.environ.setdefault("NO_PROXY", "127.0.0.1")

    def test_a_range_read_returns_exactly_the_range(self):
        with server([(200, {}, bytes(range(100)))]) as (url, _), mock.patch.object(self.rq.time, "sleep"):
            with self.assertRaises(Exception):
                self.rq.get(url, 10, 19)
        with server([(206, {}, bytes(range(10, 20)))]) as (url, seen):
            self.assertEqual(self.rq.get(url, 10, 19), bytes(range(10, 20)))
            self.assertEqual(seen, ["bytes=10-19"])

    def test_rate_limits_wait_for_retry_after(self):
        waits = []
        limited = (429, {"Retry-After": "30"}, b"slow down")
        with server([limited] * 6 + [(206, {}, b"0123456789")]) as (url, seen), \
                mock.patch.object(self.rq.time, "sleep", side_effect=waits.append):
            self.assertEqual(self.rq.get(url, 0, 9), b"0123456789")
        self.assertEqual(len(seen), 7)
        self.assertEqual(waits[:6], [30] * 6)


# ---- the quantizer --------------------------------------------------------------------------------------------------

def oracle_rows(np, rq, w, bits, group):
    """requant.affine_quantize_rows with every float32 operation done in float64 and rounded once to float32: exact
    (53 >= 2 * 24 + 2), so it depends on no SIMD path, CPU or numpy version."""
    f32, f64 = np.float32, np.float64
    shape = w.shape
    g = w.reshape(-1, shape[-1] // group, group)
    n_bins = f32((1 << bits) - 1)
    w_max = g.max(axis=-1, keepdims=True)
    w_min = g.min(axis=-1, keepdims=True)
    mask = np.abs(w_min) > np.abs(w_max)
    with np.errstate(over="ignore", invalid="ignore", divide="ignore"):
        d = (w_max.astype(f64) - w_min.astype(f64)).astype(f32)
        scales = np.maximum((d.astype(f64) / f64(n_bins)).astype(f32), f32(1e-7))
        scales = np.where(mask, scales, -scales)
        edge = np.where(mask, w_min, w_max)
        q0 = np.rint((edge.astype(f64) / scales.astype(f64)).astype(f32))
        den = np.where(q0 != 0, q0, f32(1))
        scales = np.where(q0 != 0, (edge.astype(f64) / den.astype(f64)).astype(f32), scales).astype(f32)
        biases = np.where(q0 == 0, f32(0), edge).astype(f32)
        num = (g.astype(f64) - biases.astype(f64)).astype(f32)
        q = np.clip(np.rint((num.astype(f64) / scales.astype(f64)).astype(f32)), 0, n_bins).astype(np.uint32)
    packed = rq.pack(q.reshape(-1), bits)
    s_shape = shape[:-1] + (shape[-1] // group,)
    return (packed.reshape(shape[:-1] + (shape[-1] * bits // 32,)), rq.f32_to_bf16(scales).reshape(s_shape),
            rq.f32_to_bf16(biases).reshape(s_shape))


def digest(np, parts):
    h = hashlib.sha256()
    for p in parts:
        h.update(np.ascontiguousarray(p).tobytes())
    return h.hexdigest()


@unittest.skipUnless(HAVE_NUMPY, "numpy not installed")
class Quantizer(unittest.TestCase):
    def setUp(self):
        import numpy
        self.np = numpy
        self.rq = load("requant", REQUANT)

    def test_round_trip(self):
        np, rq = self.np, self.rq
        rng = np.random.default_rng(0)
        for bits, group in ((4, 64), (4, 32), (6, 64), (8, 64)):
            w = rng.standard_normal((16, 256)).astype(np.float32)
            pw, ps, pb = rq.affine_quantize(w, bits, group)
            self.assertEqual(pw.shape, (16, 256 * bits // 32))
            q = rq.unpack(pw, bits, 256).reshape(16, 256 // group, group).astype(np.float32)
            s = (ps.astype(np.uint32) << 16).view(np.float32)[..., None]
            b = (pb.astype(np.uint32) << 16).view(np.float32)[..., None]
            # Per group: MLX's rule keeps one edge exact and zero representable (scale = edge / round(edge / scale)),
            # which can stretch the step and clip the far end, and the bf16 bias adds up to half an 8-bit step: within 2 steps.
            err = np.abs(q * s + b - w.reshape(16, 256 // group, group)).max(axis=-1)
            self.assertTrue(bool((err <= 2.0 * np.abs(s[..., 0]) + 1e-6).all()), (bits, group, float(err.max())))

    def test_selftest_passes_here(self):
        r = subprocess.run([sys.executable, str(REQUANT), "selftest"], capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("selftest ok", r.stdout)
        self.assertIn("numpy " + self.np.__version__, r.stdout)

    def test_selftest_catches_a_changed_byte(self):
        rq = self.rq
        self.assertNotEqual(rq.selftest(golden={k: "0" * 64 for k in rq.SELFTEST_GOLDEN}, out=lambda *_: None), 0)

        def truncating(x):  # bf16 by truncation instead of round-to-nearest-even
            return (self.np.ascontiguousarray(x, dtype=self.np.float32).view(self.np.uint32) >> 16).astype(self.np.uint16)

        with mock.patch.object(rq, "f32_to_bf16", truncating):
            self.assertNotEqual(rq.selftest(out=lambda *_: None), 0)

    def test_equals_the_float64_oracle(self):
        np, rq = self.np, self.rq
        for name, (w, chunk_values) in rq.selftest_cases().items():
            for bits, group in rq.SELFTEST_WIDTHS:
                with self.subTest(case=name, bits=bits, group=group), np.errstate(all="ignore"):
                    got = digest(np, rq.affine_quantize(w, bits, group, chunk_values=chunk_values))
                    self.assertEqual(got, digest(np, oracle_rows(np, rq, np.ascontiguousarray(w), bits, group)))

    def test_covers_every_width_a_recipe_uses(self):
        rq = self.rq
        mods = ["language_model.lm_head", "language_model.model.layers.0.mlp.down_proj",
                "language_model.model.layers.20.self_attn.v_proj", "language_model.model.layers.1.mlp.gate",
                "language_model.model.layers.1.mlp.shared_expert_gate",
                "language_model.model.layers.1.mlp.switch_mlp.up_proj", "language_model.model.layers.5.self_attn.q_proj"]
        used = {rq.recipe_for(recipe, mod, 40, template)
                for recipe in ("g64", "g32", "mixed46", "router8", "router8+mixed46")
                for mod in mods for template in ((4, 64), (8, 64))}
        self.assertLessEqual(used, set(rq.SELFTEST_WIDTHS))


if __name__ == "__main__":
    unittest.main()
