"""Offline tests of the dev coordinator deploy scripts in deploy/gcp/dev and
deploy/gcp/host-setup.sh. Every external command that can change state is a
stub that records its arguments. No test makes a network request or touches
a VM, a GCP project or the files of this machine outside a temporary
directory."""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEV = ROOT / "deploy/gcp/dev"
SEED = DEV / "seed-env.sh"
OVERRIDES = DEV / "env-overrides"
REQUIRED = ROOT / "deploy/gcp/prod/required-env-keys.txt"
DEFAULTS = ROOT / "deploy/gcp/prod/release-env-defaults"
PROD_ENV = ROOT / "deploy/environments/prod.env"
COMMIT = "a" * 40
DIGEST = "sha256:" + "b" * 64
REQUIRED_CHECKS = [
    "Release Integrity", "Docs Lint", "Coordinator Tests", "Coordinator Lint",
    "Prompt Sidecar Tests", "Provider Unit Tests", "Provider SDK Tests",
    "Provider Prompt Parity", "Provider Tests", "Console UI Lint & Build",
    "Swift Build + Cache",
]
REQUIRED_STATUSES = [
    "Vercel – d-inference", "Vercel – d-inference-console-ui-dev",
    "Vercel – d-inference-landing", "Vercel – darkbloom-status",
    "Vercel – eigen-homepages-darkbloom",
]

# A stub reads its rules from STUB_RULES: [name, regex over the joined
# arguments, stdout, exit code]. The first matching rule wins; no match prints
# nothing and exits 0. Every call is appended to STUB_LOG.
STUB = "#!" + sys.executable + "\n" + r'''
import json, os, re, sys
name = os.path.basename(sys.argv[0])
args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps([name] + args) + "\n")
if name == "gcloud" and args[:2] == ["compute", "ssh"] and not any(a == "--command=true" for a in args):
    sys.stdin.read()
if name == "install" and os.environ.get("STUB_INSTALL_REAL") == "1":
    from pathlib import Path
    root = Path(os.environ["STUB_ROOT"]).resolve()
    mode = None
    directory = "-d" in args
    positional = []
    skip = False
    for index, arg in enumerate(args):
        if skip:
            skip = False
            continue
        if arg in ("-m", "-o", "-g"):
            if arg == "-m":
                mode = int(args[index + 1], 8)
            skip = True
        elif arg.startswith("-m") and len(arg) > 2:
            mode = int(arg[2:], 8)
        elif arg in ("-d", "-D"):
            continue
        elif not arg.startswith("-"):
            positional.append(arg)
    targets = positional if directory else positional[-1:]
    for target in targets:
        if target == "/dev/stdin":
            continue
        resolved = Path(target).resolve(strict=False)
        if root not in resolved.parents and resolved != root:
            sys.exit(96)
    if directory:
        for target in positional:
            Path(target).mkdir(parents=True, exist_ok=True)
            if mode is not None:
                os.chmod(target, mode)
    else:
        source, target = positional[-2], Path(positional[-1])
        target.parent.mkdir(parents=True, exist_ok=True)
        data = sys.stdin.buffer.read() if source == "/dev/stdin" else Path(source).read_bytes()
        target.write_bytes(data)
        if mode is not None:
            os.chmod(target, mode)
    sys.exit(0)
if name == "stat" and args[:2] == ["-c", "%U:%G:%a"]:
    mode = os.stat(args[-1]).st_mode & 0o777
    sys.stdout.write(f"root:root:{mode:o}\n")
    sys.exit(0)
if name == "psql" and os.environ.get("STUB_EXPECT_PGDATABASE"):
    passfile = os.environ.get("PGPASSFILE", "")
    if os.environ.get("PGDATABASE") != os.environ["STUB_EXPECT_PGDATABASE"]:
        sys.exit(97)
    if not passfile or not os.path.isfile(passfile) or (os.stat(passfile).st_mode & 0o777) != 0o600:
        sys.exit(98)
state_path = os.environ["STUB_STATE"]
try:
    state = json.load(open(state_path))
except (FileNotFoundError, json.JSONDecodeError):
    state = {}
for index, (rule_name, pattern, out, code) in enumerate(json.load(open(os.environ["STUB_RULES"]))):
    if rule_name == name and re.search(pattern, " ".join(args)):
        if isinstance(out, list):
            position = state.get(str(index), 0)
            selected = out[min(position, len(out) - 1)]
            state[str(index)] = position + 1
            with open(state_path, "w") as state_file:
                json.dump(state, state_file)
            out, code = selected
        sys.stdout.write(out)
        sys.exit(code)
'''

# Every command that the scripts can use to change state. Read-only tools
# (awk, grep, sed, cmp, find, sort, jq) stay real.
MUTATORS = ["apt-get", "blkid", "caddy", "chmod", "chown", "cp", "dd", "docker", "dpkg", "gcloud",
            "gpg", "install", "ln", "mkdir", "mkfs.ext4", "mount", "mountpoint", "mv", "psql",
            "pg_isready", "rm", "sudo", "systemctl", "systemd-run", "tee", "usermod", "findmnt",
            "lsblk", "wipefs", "stat", "curl", "id", "dig", "git", "gh", "hostname",
            "docker-credential-gcloud"]



def gnu_ln_available():
    """swap.sh swaps its rollback symlinks with GNU `ln -T`, as on the Ubuntu VM."""
    probe = subprocess.run(["ln", "--version"], capture_output=True, text=True)
    return probe.returncode == 0 and "GNU" in probe.stdout


requires_gnu_ln = unittest.skipUnless(
    gnu_ln_available(), "swap.sh uses GNU ln -T (the Ubuntu VM has it; macOS ln does not)")


class Sandbox:
    def __init__(self, testcase, stubs, rules):
        tmp = tempfile.TemporaryDirectory()
        testcase.addCleanup(tmp.cleanup)
        # Resolve the temp root: on macOS it is under a symlink (/var -> /private/var),
        # and the scripts compare resolved paths against the roots they are given.
        self.root = Path(tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.log.touch()
        self.rules_file = self.root / "rules.json"
        self.state_file = self.root / "state.json"
        self.state_file.write_text("{}")
        self.set_rules(rules)
        for name in stubs:
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.env = {
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(self.root / "home"),
            "TMPDIR": str(self.root),
            "STUB_LOG": str(self.log),
            "STUB_RULES": str(self.rules_file),
            "STUB_STATE": str(self.state_file),
            "STUB_ROOT": str(self.root),
            "SKIP_PERSISTENCE_CHECK": "1",
            "LC_ALL": "C",
        }
        (self.root / "home").mkdir()

    def set_rules(self, rules):
        self.rules_file.write_text(json.dumps(rules))
        if hasattr(self, "state_file"):
            self.state_file.write_text("{}")

    def run(self, argv, extra=None, cwd=ROOT):
        return subprocess.run(["bash", *map(str, argv)], env={**self.env, **(extra or {})}, cwd=cwd,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def calls(self, name=None):
        out = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [c for c in out if name is None or c[0] == name]


def dev_host_rules(project="darkbloom-dev", missing=(), multiline=()):
    rules = [["id", "", "0\n", 0], ["curl", "metadata.google.internal", project, 0]]
    for name in missing:
        rules.append(["gcloud", f"--secret={re.escape(name)}$", "", 1])
    for name in multiline:
        rules.append(["gcloud", f"--secret={re.escape(name)}$", "line-one\nline-two", 0])
    # The value is printed without a newline, like gcloud secrets versions access.
    rules.append(["gcloud", "secrets versions access", "SECRET-FIXTURE-VALUE", 0])
    return rules


def snapshot(path):
    result = {}
    for p in sorted(Path(path).rglob("*")):
        st = p.lstat()
        digest = hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else ""
        result[str(p)] = (stat.S_IMODE(st.st_mode), st.st_mtime_ns, digest)
    return result


def env_lines(path):
    out = {}
    for line in Path(path).read_text().splitlines():
        if line and not line.startswith("#"):
            key, _, value = line.partition("=")
            out[key] = value
    return out


def manifest_keys(path):
    keys = set()
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            keys.add(line.split("=", 1)[0])
    return keys


class DevEnvContractTests(unittest.TestCase):
    def test_every_required_key_has_a_dev_source(self):
        overlay = env_lines(OVERRIDES)
        prod = {k for k in env_lines(PROD_ENV) if k.startswith("EIGENINFERENCE_")}
        sources = set(overlay) | manifest_keys(DEFAULTS) | prod
        missing = sorted(manifest_keys(REQUIRED) - sources)
        self.assertEqual(missing, [], "required keys with no dev source (overlay, release default or prod.env)")

    def test_overlay_is_values_only_with_secret_references(self):
        text = OVERRIDES.read_text()
        self.assertNotIn("#", text)
        for key, value in env_lines(OVERRIDES).items():
            self.assertRegex(key, r"^[A-Z_][A-Z0-9_]*$")
            if value.startswith("secret-manager:"):
                self.assertRegex(value, r"^secret-manager:[a-z0-9-]+$")

    def test_host_names_live_only_in_the_overlay(self):
        overlay = env_lines(OVERRIDES)
        api, console = overlay["DOMAIN"], overlay["EIGENINFERENCE_CONSOLE_URL"]
        self.assertRegex(api, r"^[a-z0-9.-]+$")
        self.assertTrue(console.startswith("https://"))
        files = [*DEV.glob("*.sh"), ROOT / "deploy/gcp/host-setup.sh", ROOT / "scripts/smoke-dev.sh"]
        for path in files:
            self.assertNotIn(api, path.read_text(), path)
            self.assertNotIn(console.removeprefix("https://"), path.read_text(), path)
        self.assertEqual(OVERRIDES.read_text().count(api), 1)
        self.assertEqual(OVERRIDES.read_text().count(console.removeprefix("https://")), 1)


class SeedEnvTests(unittest.TestCase):
    def sandbox(self, **rules):
        box = Sandbox(self, ["id", "curl", "gcloud", "stat"], dev_host_rules(**rules))
        box.env_dir = box.root / "etc"
        box.env["ENV_DIR"] = str(box.env_dir)
        return box

    def assert_no_value_printed(self, result):
        self.assertNotIn("SECRET-FIXTURE-VALUE", result.stdout + result.stderr)

    def test_seed_writes_a_file_that_passes_the_production_check(self):
        box = self.sandbox(missing=["eigeninference-dd-api-key"])
        result = box.run([SEED, "--seed"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_no_value_printed(result)
        env_file = box.env_dir / "env"
        self.assertEqual(stat.S_IMODE(env_file.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(box.env_dir.stat().st_mode), 0o700)
        env = env_lines(env_file)
        overlay = env_lines(OVERRIDES)
        self.assertEqual(env["EIGENINFERENCE_BASE_URL"], "https://" + overlay["DOMAIN"])
        self.assertEqual(env["CORS_ORIGIN"], overlay["EIGENINFERENCE_CONSOLE_URL"])
        self.assertEqual(env["EIGENINFERENCE_MIN_TRUST"], "self_signed")
        self.assertEqual(env["EIGENINFERENCE_DEPLOYMENT_ENVIRONMENT"], "development")
        self.assertEqual(env["EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ENABLED"], "false")
        self.assertEqual(env["EIGENINFERENCE_CACHE_ROUTING_MODE"], "off")
        self.assertEqual(env["EIGENINFERENCE_DRAIN_GRACE"], "45s")
        self.assertEqual(env["EIGENINFERENCE_MIN_PROVIDER_VERSION"], env_lines(PROD_ENV)["EIGENINFERENCE_MIN_PROVIDER_VERSION"])
        self.assertEqual(env["EIGENINFERENCE_PROMPT_SIDECAR_ENABLED"], "true")
        self.assertEqual(env["EIGENINFERENCE_DATABASE_URL"], "SECRET-FIXTURE-VALUE")
        self.assertNotIn("DD_API_KEY", env)
        self.assertNotIn("MODEL_REGISTRY_CDN_BASE_URL", env)
        self.assertIn("DD_API_KEY(eigeninference-dd-api-key)", result.stdout)
        for key in manifest_keys(REQUIRED):
            self.assertTrue(env.get(key), key)
        for call in box.calls("gcloud"):
            self.assertEqual(call[1:5], ["--quiet", "secrets", "versions", "access"])
            self.assertIn("--project=darkbloom-dev", call)

    def test_missing_required_secret_writes_nothing(self):
        box = self.sandbox(missing=["eigeninference-database-url"])
        result = box.run([SEED, "--seed"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EIGENINFERENCE_DATABASE_URL", result.stderr)
        self.assertEqual([p.name for p in box.env_dir.iterdir()], [])

    def test_multiline_secret_is_refused(self):
        box = self.sandbox(multiline=["eigeninference-privy-verification-key"])
        result = box.run([SEED, "--seed"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EIGENINFERENCE_PRIVY_VERIFICATION_KEY", result.stderr)
        self.assertNotIn("line-one", result.stdout + result.stderr)
        self.assertEqual([p.name for p in box.env_dir.iterdir()], [])

    def test_failed_reseed_keeps_the_live_file(self):
        box = self.sandbox()
        self.assertEqual(box.run([SEED, "--seed"]).returncode, 0)
        before = snapshot(box.env_dir)
        box.set_rules(dev_host_rules(missing=["eigeninference-admin-key"]))
        result = box.run([SEED, "--reseed"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(snapshot(box.env_dir), before)

    def test_reseed_replaces_the_file_and_keeps_the_old_one(self):
        box = self.sandbox()
        self.assertEqual(box.run([SEED, "--seed"]).returncode, 0)
        env_file = box.env_dir / "env"
        env_file.write_text(env_file.read_text() + "HAND_ADDED=1\n")
        result = box.run([SEED, "--reseed"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("HAND_ADDED", env_lines(env_file))
        backups = list(box.env_dir.glob("env.pre-reseed.*"))
        self.assertEqual(len(backups), 1)
        self.assertIn("HAND_ADDED", env_lines(backups[0]))
        self.assertIn("HAND_ADDED", result.stdout)
        self.assert_no_value_printed(result)

    def test_seed_keeps_an_existing_file(self):
        box = self.sandbox()
        self.assertEqual(box.run([SEED, "--seed"]).returncode, 0)
        before = snapshot(box.env_dir)
        calls = len(box.calls("gcloud"))
        self.assertEqual(box.run([SEED, "--seed"]).returncode, 0)
        self.assertEqual(snapshot(box.env_dir), before)
        self.assertEqual(len(box.calls("gcloud")), calls)

    def test_other_project_is_refused_before_any_change(self):
        box = self.sandbox(project="darkbloom-mainnet")
        for mode in ("--seed", "--reseed", "--check"):
            result = box.run([SEED, mode])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not darkbloom-dev", result.stderr)
        self.assertEqual(box.calls("gcloud"), [])
        self.assertFalse(box.env_dir.exists())

    def test_check_is_read_only(self):
        box = self.sandbox()
        result = box.run([SEED])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stdout)
        self.assertFalse(box.env_dir.exists())
        self.assertEqual(box.run([SEED, "--seed"]).returncode, 0)
        env_file = box.env_dir / "env"
        env_file.write_text(env_file.read_text().replace("EIGENINFERENCE_MIN_TRUST=self_signed",
                                                          "EIGENINFERENCE_MIN_TRUST=hardware"))
        before = snapshot(box.env_dir)
        calls = len(box.calls("gcloud"))
        result = box.run([SEED, "--check"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("REPORT DRIFT EIGENINFERENCE_MIN_TRUST", result.stdout)
        self.assertNotIn("hardware", result.stdout)
        self.assertEqual(snapshot(box.env_dir), before)
        self.assertEqual(len(box.calls("gcloud")), calls)


def read_only(call):
    """True when a recorded call cannot change state."""
    name, args = call[0], call[1:]
    joined = " ".join(args)
    if name in ("id", "dig", "findmnt", "pg_isready", "hostname", "lsblk", "stat"):
        return True
    if name == "wipefs":
        return args[:1] == ["-n"]
    if name == "curl":
        return "metadata.google.internal" in joined
    if name == "mountpoint":
        return args[:1] == ["-q"]
    if name == "dpkg":
        return args[:1] in (["-s"], ["--print-architecture"])
    if name == "systemctl":
        return args[:1] in (["is-active"], ["is-enabled"])
    if name == "docker":
        return args[:1] in (["inspect"], ["ps"], ["image"]) and "prune" not in args
    if name == "gh":
        return args[:2] == ["variable", "get"] or args[:1] == ["api"]
    if name == "git":
        return args[:1] in (["rev-parse"], ["status"], ["ls-remote"], ["archive"])
    if name == "sudo":
        return True  # the command that sudo runs is a separate stub or a checked script
    if name == "gcloud":
        allowed = [
            ["auth", "list"], ["auth", "print-access-token"], ["projects", "describe"],
            ["compute", "instances", "describe"], ["secrets", "versions", "list"],
            ["sql", "instances", "describe"], ["builds", "triggers", "describe"], ["builds", "list"],
            ["artifacts", "docker", "images", "describe"],
        ]
        if any(args[:len(a)] == a for a in allowed):
            return True
        # IAP SSH runs either "true" or the read-only on-VM part of preflight.sh.
        return args[:2] == ["compute", "ssh"] and any(
            a == "--command=true" or ("preflight.sh\" --on-vm" in a and "rm -rf" in a) for a in args)
    return False


class ZeroMutationTests(unittest.TestCase):
    def assert_read_only(self, box):
        calls = box.calls()
        self.assertTrue(calls)
        bad = [c for c in calls if not read_only(c)]
        self.assertEqual(bad, [], "mutating calls")

    def test_host_setup_check_makes_no_mutating_call(self):
        box = Sandbox(self, MUTATORS, dev_host_rules() + [["systemctl", "", "", 3]])
        result = box.run([ROOT / "deploy/gcp/host-setup.sh", "--check"])
        self.assertNotEqual(result.returncode, 0)  # nothing is set up in the sandbox
        self.assertIn("FAIL", result.stdout)
        self.assert_read_only(box)
        default = box.run([ROOT / "deploy/gcp/host-setup.sh"])
        self.assertEqual(default.stdout, result.stdout)
        self.assert_read_only(box)

    def test_host_setup_refuses_other_project(self):
        box = Sandbox(self, MUTATORS, dev_host_rules(project="darkbloom-mainnet"))
        result = box.run([ROOT / "deploy/gcp/host-setup.sh", "--apply"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c[0] for c in box.calls()], ["id", "curl"])

    def test_host_setup_never_formats_without_one_shot_blank_disk_authorization(self):
        base = dev_host_rules() + [
            ["lsblk", "-o TYPE", "disk\n", 0],
            ["lsblk", "-o FSTYPE", "\n", 0],
            ["lsblk", "-o MOUNTPOINTS", "", 0],
            ["wipefs", "^-n", "", 0],
        ]
        box = Sandbox(self, MUTATORS, base)
        result = box.run([ROOT / "deploy/gcp/host-setup.sh", "--apply"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verified blank", result.stderr)
        self.assertEqual(box.calls("mkfs.ext4"), [])

        box = Sandbox(self, MUTATORS, base[:-1] + [["wipefs", "^-n", "gpt\n", 0]])
        result = box.run([ROOT / "deploy/gcp/host-setup.sh", "--apply", "--format-data-disk"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing signature", result.stderr)
        self.assertEqual(box.calls("mkfs.ext4"), [])

        box = Sandbox(self, MUTATORS, base)
        probe_error = [rule[:] for rule in base]
        for rule in probe_error:
            if rule[0] == "lsblk" and "MOUNTPOINTS" in rule[1]:
                rule[3] = 1
        box.set_rules(probe_error)
        result = box.run([ROOT / "deploy/gcp/host-setup.sh", "--apply", "--format-data-disk"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot determine whether", result.stderr)
        self.assertEqual(box.calls("mkfs.ext4"), [])

    def test_preflight_makes_no_mutating_call(self):
        rules = [
            ["git", "^ls-remote", f"{COMMIT}\trefs/heads/master\n", 0],
            ["git", "^rev-parse", COMMIT + "\n", 0],
            ["git", "^archive", "archive", 0],
            ["gcloud", "^auth list", "dev@example.invalid\n", 0],
            ["gcloud", "^projects describe", "ACTIVE\n", 0],
            ["gcloud", "instances describe.*value\\(status\\)", "RUNNING\n", 0],
            ["gcloud", "instances describe.*natIP", "192.0.2.10\n", 0],
            ["gcloud", "^secrets versions list", "projects/x/secrets/y/versions/1\n", 0],
            ["gcloud", "sql instances describe.*value\\(state\\)", "RUNNABLE\n", 0],
            ["gcloud", "sql instances describe.*type", "PRIVATE\n", 0],
            ["gcloud", "^builds triggers describe.*filename", "deploy/gcp/cloudbuild-prod.yaml\n", 0],
            ["gcloud", "^builds triggers describe.*value\\(id\\)", "trigger-id\n", 0],
            ["gcloud", "^builds list.*buildTriggerId=trigger-id", "build-id\n", 0],
            ["gcloud", "^artifacts docker images describe", DIGEST + "\n", 0],
            ["gcloud", "^compute ssh", "PASS on-VM fixture\n", 0],
            ["dig", "", "192.0.2.10\n", 0],
        ]
        box = Sandbox(self, MUTATORS, rules)
        result = box.run([DEV / "preflight.sh"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("FAIL", result.stdout)
        self.assertIn("PASS DNS", result.stdout)
        self.assertIn("PASS on-VM fixture", result.stdout)
        self.assertEqual(len([c for c in box.calls("gcloud") if c[1:3] == ["secrets", "versions"]]),
                         len({v for v in env_lines(OVERRIDES).values() if v.startswith("secret-manager:")}))
        self.assert_read_only(box)

        box.set_rules([["gcloud", "^auth list", "", 0]])
        result = box.run([DEV / "preflight.sh"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL no valid gcloud login", result.stdout)
        self.assert_read_only(box)

    def test_preflight_vm_part_makes_no_mutating_call(self):
        rules = dev_host_rules() + [["systemctl", "", "", 3]]
        box = Sandbox(self, MUTATORS, rules)
        # sudo runs the command, so the commands behind it are stubs too.
        (box.bin / "sudo").write_text('#!/bin/sh\nprintf \'["sudo"]\\n\' >> "$STUB_LOG"\nexec "$@"\n')
        result = box.run([DEV / "preflight.sh", "--on-vm"])
        self.assertNotEqual(result.returncode, 0)  # no host setup in the sandbox
        self.assertIn("host-setup --check: FAIL", result.stdout)
        self.assertIn("seed-env --check: FAIL", result.stdout)
        self.assert_read_only(box)

    def deploy_rules(self, master=COMMIT, paused="false\n", paused_code=0):
        green_runs = [
            {"name": name, "status": "completed", "conclusion": "success"}
            for name in REQUIRED_CHECKS
        ]
        green_checks = json.dumps([{"total_count": len(green_runs), "check_runs": green_runs}])
        status_values = [{"context": name, "state": "success"} for name in REQUIRED_STATUSES]
        green_statuses = json.dumps([{
            "total_count": len(status_values), "statuses": status_values,
        }])
        return [
            ["gh", "^variable get DEV_DEPLOY_PAUSED", paused, paused_code],
            ["gh", "^api .*check-runs", green_checks, 0],
            ["gh", "^api .*commits/.*/status", green_statuses, 0],
            ["gcloud", "^auth list", "dev@example.invalid\n", 0],
            ["git", "^ls-remote", f"{master}\trefs/heads/master\n", 0],
            ["git", "^rev-parse", COMMIT + "\n", 0],
            ["gcloud", "triggers describe.*filename", "deploy/gcp/cloudbuild-prod.yaml\n", 0],
            ["gcloud", "triggers describe.*value\\(id\\)", "trigger-id\n", 0],
            ["gcloud", "^builds list.*SUCCESS", "build-id\n", 0],
            ["gcloud", "^artifacts docker images describe", DIGEST + "\n", 0],
        ]

    def test_deploy_dry_run_makes_no_mutating_call(self):
        box = Sandbox(self, MUTATORS, self.deploy_rules())
        out = box.root / "github_output"
        result = box.run([DEV / "deploy.sh", "--dry-run"], {"GITHUB_OUTPUT": str(out)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"digest={DIGEST}", result.stdout)
        self.assertIn("DRY-RUN ssh: sudo systemd-run", result.stdout)
        self.assertIn(f"CANDIDATE_COMMIT={COMMIT}", result.stdout)
        self.assertIn("MIGRATE_ONLY=1", result.stdout)
        self.assertEqual(out.read_text(), "deployed=false\n")
        self.assertEqual([c for c in box.calls("gcloud") if c[1] == "compute"], [])
        self.assertEqual([c for c in box.calls("git") if c[1] == "archive"], [])
        self.assert_read_only(box)

        result = box.run([DEV / "deploy.sh", "rollback", "--dry-run"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MODE=rollback", result.stdout)
        self.assert_read_only(box)

    def assert_paused_refusal(self, box, result):
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("deploys are paused or the pause state is unknown", result.stderr)
        self.assertIn("nothing changed", result.stderr)
        self.assertEqual(box.calls("gcloud"), [])
        self.assertEqual(box.calls("git"), [])
        self.assert_read_only(box)

    def test_deploy_refuses_when_paused(self):
        box = Sandbox(self, MUTATORS, self.deploy_rules(paused="true\n"))
        out = box.root / "github_output"
        for argv in ([], ["rollback"]):
            result = box.run([DEV / "deploy.sh", *argv], {"GITHUB_OUTPUT": str(out)})
            self.assert_paused_refusal(box, result)
            self.assertIn("REPORT DEV_DEPLOY_PAUSED=true (from gh variable get; initial gate)", result.stdout)
        self.assertEqual(out.read_text(), "deployed=false\ndeployed=false\n")
        result = box.run([DEV / "deploy.sh"], {"DEV_DEPLOY_PAUSED": "true"})
        self.assert_paused_refusal(box, result)
        self.assertIn("REPORT DEV_DEPLOY_PAUSED=true (from environment; initial gate)", result.stdout)

    def test_deploy_refuses_when_the_pause_state_is_unknown(self):
        box = Sandbox(self, MUTATORS, self.deploy_rules(paused="", paused_code=1))
        result = box.run([DEV / "deploy.sh"])
        self.assert_paused_refusal(box, result)
        self.assertIn("DEV_DEPLOY_PAUSED=<unreadable>", result.stdout)
        # An unset repository variable reaches the workflow as an empty value.
        result = box.run([DEV / "deploy.sh"], {"DEV_DEPLOY_PAUSED": ""})
        self.assert_paused_refusal(box, result)
        self.assertIn("DEV_DEPLOY_PAUSED=<empty>", result.stdout)

    def test_dry_run_reports_the_pause_and_continues(self):
        box = Sandbox(self, MUTATORS, self.deploy_rules(paused="true\n"))
        result = box.run([DEV / "deploy.sh", "--dry-run"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("REPORT DEV_DEPLOY_PAUSED=true", result.stdout)
        self.assertIn("REPORT a real run stops here", result.stdout)
        self.assertIn(f"digest={DIGEST}", result.stdout)
        self.assert_read_only(box)

    def test_override_with_a_reason_proceeds(self):
        rules = self.deploy_rules(paused="true\n") + [
            ["gcloud", "^compute ssh.*journalctl", f"REPORT fixture\nOK {COMMIT} drain_s=0 start_to_ready_s=1\n", 0],
            ["git", "^archive", "archive", 0],
        ]
        box = Sandbox(self, MUTATORS, rules)
        out = box.root / "github_output"
        self.assertEqual(box.run([DEV / "deploy.sh", "--override-pause"]).returncode, 2)
        result = box.run([DEV / "deploy.sh", "--override-pause", "first deploy DBLM-559"],
                         {"GITHUB_OUTPUT": str(out)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r"REPORT pause override by dev@example\.invalid \(.*\): first deploy DBLM-559")
        self.assertIn(f"OK {COMMIT}", result.stdout)
        self.assertEqual(out.read_text(), "deployed=true\n")
        ssh = [c for c in box.calls("gcloud") if c[1:3] == ["compute", "ssh"]]
        self.assertEqual(len(ssh), 3)  # ship the files, start the unit, read the result
        self.assertTrue(any("systemd-run" in a and f"CANDIDATE_DIGEST={DIGEST}" in a for a in ssh[1]))

    def test_deploy_stops_when_master_moved(self):
        box = Sandbox(self, MUTATORS, self.deploy_rules(master="c" * 40))
        out = box.root / "github_output"
        result = box.run([DEV / "deploy.sh"], {"GITHUB_OUTPUT": str(out), "ON_SUPERSEDED": "skip"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is not origin/master", result.stdout)
        self.assertEqual(out.read_text(), "deployed=false\n")
        self.assertEqual(box.calls("gcloud"), [])
        result = box.run([DEV / "deploy.sh"])
        self.assertEqual(result.returncode, 2)

    def test_deploy_rechecks_live_pause_before_ssh(self):
        rules = self.deploy_rules()
        rules[0][2] = [["false\n", 0], ["true\n", 0]]
        box = Sandbox(self, MUTATORS, rules)
        result = box.run([DEV / "deploy.sh"])
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("live gate", result.stdout)
        self.assertEqual([c for c in box.calls("gcloud") if c[1:3] == ["compute", "ssh"]], [])

    def test_deploy_rechecks_master_before_ssh(self):
        rules = self.deploy_rules()
        for rule in rules:
            if rule[0] == "git" and rule[1] == "^ls-remote":
                rule[2] = [[f"{COMMIT}\trefs/heads/master\n", 0], [f"{'c' * 40}\trefs/heads/master\n", 0]]
        box = Sandbox(self, MUTATORS, rules)
        result = box.run([DEV / "deploy.sh"], {"ON_SUPERSEDED": "skip"})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no longer origin/master", result.stdout)
        self.assertEqual([c for c in box.calls("gcloud") if c[1:3] == ["compute", "ssh"]], [])

    def test_ci_failures_require_an_exact_nonstale_waiver(self):
        failed_runs = [
            {"name": name, "status": "completed",
             "conclusion": "failure" if name == "Coordinator Tests" else "success"}
            for name in REQUIRED_CHECKS
        ]
        failed_checks = json.dumps([{"total_count": len(failed_runs), "check_runs": failed_runs}])
        rules = self.deploy_rules()
        for rule in rules:
            if rule[0] == "gh" and "check-runs" in rule[1]:
                rule[2] = failed_checks
        box = Sandbox(self, MUTATORS, rules)
        result = box.run([DEV / "deploy.sh"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not explicitly waived: Coordinator Tests", result.stderr)
        self.assertEqual([c for c in box.calls("gcloud") if c[1:3] == ["compute", "ssh"]], [])

        result = box.run([DEV / "deploy.sh", "--allow-ci-failure", "Wrong Check",
                          "--ci-waiver-reason", "owner reviewed base failure"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stale or misspelled", result.stderr)

    def test_required_checks_must_conclude_success(self):
        for conclusion in ("skipped", "neutral", None):
            with self.subTest(conclusion=conclusion):
                runs = [
                    {"name": name, "status": "completed",
                     "conclusion": conclusion if name == "Coordinator Tests" else "success"}
                    for name in REQUIRED_CHECKS
                ]
                rules = self.deploy_rules()
                for rule in rules:
                    if rule[0] == "gh" and "check-runs" in rule[1]:
                        rule[2] = json.dumps([{"total_count": len(runs), "check_runs": runs}])
                box = Sandbox(self, MUTATORS, rules)
                result = box.run([DEV / "deploy.sh", "--dry-run"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CI failure is not explicitly waived: Coordinator Tests", result.stderr)

    def test_status_inventory_is_complete_and_has_unique_contexts(self):
        required = [{"context": name, "state": "success"} for name in REQUIRED_STATUSES]
        extras = [{"context": f"optional-{index}", "state": "success"} for index in range(25)]
        cases = (
            ("omitted later status", [{"total_count": 31, "statuses": required + extras}],
             "status-context response is empty or truncated"),
            ("later failure", [
                {"total_count": 31, "statuses": required + extras},
                {"total_count": 31, "statuses": [{"context": "hidden-failure", "state": "failure"}]},
             ], "CI failure is not explicitly waived: hidden-failure"),
            ("later pending", [
                {"total_count": 31, "statuses": required + extras},
                {"total_count": 31, "statuses": [{"context": "hidden-pending", "state": "pending"}]},
             ], "CI is not complete for"),
            ("malformed total", [{"total_count": "31", "statuses": required}],
             "invalid GitHub status-context response"),
            ("case-variant duplicate", [{"total_count": len(required) + 1,
                "statuses": required + [{"context": REQUIRED_STATUSES[0].lower(), "state": "success"}]}],
             "contains duplicate contexts"),
        )
        for label, pages, expected in cases:
            with self.subTest(label=label):
                rules = self.deploy_rules()
                for rule in rules:
                    if rule[0] == "gh" and "commits/.*/status" in rule[1]:
                        rule[2] = json.dumps(pages)
                box = Sandbox(self, MUTATORS, rules)
                result = box.run([DEV / "deploy.sh", "--dry-run"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertEqual([call for call in box.calls("gcloud") if call[1:3] == ["compute", "ssh"]], [])

    def test_ci_waivers_are_rejected_under_github_actions(self):
        box = Sandbox(self, MUTATORS, self.deploy_rules())
        result = box.run([DEV / "deploy.sh", "--allow-ci-failure", "Coordinator Tests",
                          "--ci-waiver-reason", "owner reviewed base failure"],
                         {"GITHUB_ACTIONS": "true"})
        self.assertEqual(result.returncode, 2)
        self.assertIn("human-only", result.stderr)
        self.assertEqual(box.calls(), [])

    def test_malformed_status_states_are_not_waiver_eligible(self):
        for state in ("", "unknown"):
            with self.subTest(state=state):
                values = [{"context": name, "state": "success"} for name in REQUIRED_STATUSES]
                values.append({"context": "malformed-state", "state": state})
                rules = self.deploy_rules()
                for rule in rules:
                    if rule[0] == "gh" and "commits/.*/status" in rule[1]:
                        rule[2] = json.dumps([{"total_count": len(values), "statuses": values}])
                box = Sandbox(self, MUTATORS, rules)
                result = box.run([
                    DEV / "deploy.sh", "--dry-run",
                    "--allow-ci-failure", "malformed-state",
                    "--ci-waiver-reason", "owner reviewed optional context",
                ])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid GitHub status-context response", result.stderr)
                self.assert_read_only(box)

    def test_override_reasons_must_be_nonblank_single_lines(self):
        box = Sandbox(self, MUTATORS, self.deploy_rules(paused="true\n"))
        for reason in ("   ", "line one\nline two", "line one\rline two"):
            result = box.run([DEV / "deploy.sh", "--override-pause", reason])
            self.assertEqual(result.returncode, 2)
        self.assertEqual(box.calls("gcloud"), [])

    def seeded_swap_box(self, with_current=True):
        stubs = ["id", "curl", "gcloud", "stat", "psql", "docker", "date", "install", "chown"]
        box = Sandbox(self, stubs, dev_host_rules())
        env_dir = box.root / "etc-d-inference"
        env_dir.mkdir(mode=0o700)
        box.env["ENV_DIR"] = str(env_dir)
        seeded = box.run([SEED, "--seed"])
        self.assertEqual(seeded.returncode, 0, seeded.stdout + seeded.stderr)
        env_file = env_dir / "env"
        env_file.write_text(env_file.read_text().replace(
            "EIGENINFERENCE_DATABASE_URL=SECRET-FIXTURE-VALUE",
            "EIGENINFERENCE_DATABASE_URL=postgresql://coordinator:fixture-password@192.0.2.5:5432/eigeninference?sslmode=require",
        ))
        box.log.write_text("")
        state = box.root / "state"
        deploy_root = box.root / "deploy-root"
        envlib = box.root / "envlib"
        refresh_bin = box.root / "sbin/darkbloom-refresh-env"
        deploy_root.mkdir()
        envlib.mkdir()
        refresh_bin.parent.mkdir()
        old = deploy_root / "old"
        old.mkdir()
        if with_current:
            (deploy_root / "current").symlink_to(old)
        refresh_bin.write_text("old refresh\n")
        (envlib / "required-env-keys.txt").write_text("old required\n")
        (envlib / "release-env-defaults").write_text("old defaults\n")
        extra = {
            "LIB": str(ROOT), "RESULT": str(box.root / "result"),
            "ENV_FILE": str(env_dir / "env"), "STATE": str(state),
            "DEPLOY_ROOT": str(deploy_root), "ENVLIB": str(envlib),
            "REFRESH_BIN": str(refresh_bin), "MIGRATE_ONLY": "0",
            "CANDIDATE_COMMIT": COMMIT, "CANDIDATE_VERSION": "0.9.17",
            "CANDIDATE_DIGEST": DIGEST, "STUB_EXPECT_PGDATABASE": "eigeninference",
            "STUB_INSTALL_REAL": "1",
        }
        return box, extra, (refresh_bin, envlib, deploy_root)

    def test_swap_seed_failure_precedes_every_mutation(self):
        box, extra, _ = self.seeded_swap_box()
        env_file = Path(extra["ENV_FILE"])
        env_file.write_text("\n".join(
            line for line in env_file.read_text().splitlines()
            if not line.startswith("EIGENINFERENCE_DATABASE_URL=")
        ) + "\n")
        box.set_rules(dev_host_rules())
        result = box.run([DEV / "swap.sh"], extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("seed-env.sh --check failed", Path(extra["RESULT"]).read_text())
        self.assertEqual(box.calls("psql"), [])
        self.assertEqual(box.calls("docker"), [])
        self.assertEqual(box.calls("install"), [])

    def test_swap_psql_uses_pgdatabase_not_argv(self):
        box, extra, _ = self.seeded_swap_box()
        rules = dev_host_rules() + [["psql", "select 1", "", 1]]
        box.set_rules(rules)
        result = box.run([DEV / "swap.sh"], extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(box.calls("psql"))
        for call in box.calls("psql"):
            self.assertNotIn("fixture-password", " ".join(call))
            self.assertNotIn("postgresql://", " ".join(call))
        self.assertNotIn("fixture-password", result.stdout + result.stderr)
        self.assertEqual(list(Path(extra["STATE"]).glob(".pg.*")), [])

    def assert_private_temp_setup_failure(self, command, rule):
        box, extra, _ = self.seeded_swap_box()
        for name in (command, "python3"):
            path = box.bin / name
            path.write_text(STUB)
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        box.set_rules(dev_host_rules() + [rule])
        result = box.run([DEV / "swap.sh"], extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(box.calls("python3"), [])
        self.assertEqual(box.calls("psql"), [])
        self.assertEqual(list(Path(extra["STATE"]).glob(".pg.*")), [])

    def test_swap_stops_when_private_temp_directory_creation_fails(self):
        self.assert_private_temp_setup_failure("mktemp", ["mktemp", "^-d", "", 73])

    def test_swap_stops_when_private_temp_directory_chmod_fails(self):
        self.assert_private_temp_setup_failure("chmod", ["chmod", "^0700", "", 74])

    def test_failed_private_credential_cleanup_is_reported(self):
        box, extra, _ = self.seeded_swap_box()
        path = box.bin / "rm"
        path.write_text(STUB)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        box.set_rules(dev_host_rules() + [
            ["psql", "select 1", "", 41],
            ["rm", "\\.pg\\.", "", 55],
        ])
        result = box.run([DEV / "swap.sh"], extra)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("private database credential cleanup failed", result.stderr)
        self.assertIn("private database credential cleanup failed", Path(extra["RESULT"]).read_text())
        self.assertEqual(len(list(Path(extra["STATE"]).glob(".pg.*"))), 1)

    @requires_gnu_ln
    def test_rollback_state_publication_failure_preserves_prior_record(self):
        box, extra, _ = self.seeded_swap_box()
        state = Path(extra["STATE"])
        state.mkdir()
        prior = state / "rollback-state"
        prior_bytes = b"prior rollback record\n"
        prior.write_bytes(prior_bytes)
        prior.chmod(0o600)
        path = box.bin / "mv"
        path.write_text(STUB)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        box.set_rules(dev_host_rules() + [
            ["psql", "select count", "0\n", 0],
            ["docker", "^pull", "", 0],
            ["docker", "image inspect.*image.revision", COMMIT + "\n", 0],
            ["docker", "image inspect.*image.version", "0.9.17\n", 0],
            ["docker", "^container inspect coordinator", "", 1],
            ["mv", "\\.rollback-state\\.publish\\.", "", 63],
        ])
        result = box.run([DEV / "swap.sh"], extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not atomically publish rollback state", Path(extra["RESULT"]).read_text())
        self.assertEqual(prior.read_bytes(), prior_bytes)
        self.assertEqual(box.calls("docker")[-1][1], "container")
        self.assertEqual([call for call in box.calls("docker") if call[1] == "run"], [])

    def test_swap_rejects_dangling_current_before_mutation(self):
        box, extra, paths = self.seeded_swap_box()
        _, _, deploy_root = paths
        (deploy_root / "current").unlink()
        (deploy_root / "current").symlink_to(deploy_root / "missing")
        box.set_rules(dev_host_rules())
        result = box.run([DEV / "swap.sh"], extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertRegex(Path(extra["RESULT"]).read_text(),
                         r"dangling or unreadable symlink|do not resolve to an existing directory")
        self.assertEqual(box.calls("psql"), [])
        self.assertEqual(box.calls("docker"), [])
        self.assertEqual(box.calls("install"), [])

    @requires_gnu_ln
    def test_unexpected_post_swap_failure_triggers_first_deploy_restoration(self):
        box, extra, paths = self.seeded_swap_box(with_current=False)
        refresh_bin, envlib, deploy_root = paths
        env_file = Path(extra["ENV_FILE"])
        before_env = env_file.read_bytes()
        before_tools = [refresh_bin.read_bytes(), (envlib / "required-env-keys.txt").read_bytes(),
                        (envlib / "release-env-defaults").read_bytes()]
        absent_current = deploy_root / "current"
        readlink_probe = subprocess.run(["readlink", "-f", str(absent_current)], text=True,
                                        capture_output=True, check=False)
        self.assertEqual(readlink_probe.returncode, 0)
        self.assertEqual(readlink_probe.stdout.strip(), str(absent_current))
        state = Path(extra["STATE"])
        state.mkdir()
        prior_rollback = state / "rollback-state"
        prior_rollback.write_text("prior rollback fixture\n")
        prior_rollback.chmod(0o600)
        rules = dev_host_rules() + [
            ["psql", "select count", "0\n", 0],
            ["docker", "^pull", "", 0],
            ["docker", "image inspect.*image.revision", COMMIT + "\n", 0],
            ["docker", "image inspect.*image.version", "0.9.17\n", 0],
            ["docker", "^container inspect coordinator", [["", 1], ["{}\n", 0]], 0],
            ["docker", "^run", "candidate-container\n", 0],
            ["docker", "^inspect coordinator --format.*Config.Env", "EIGENINFERENCE_DRAIN_GRACE=45s\n", 0],
            ["date", r"^\+%s$", [["100\n", 0], ["101\n", 0], ["", 42]], 0],
            ["curl", "localhost:8080/health", json.dumps({"status": "ok", "build_commit": COMMIT,
                                                            "build_date": "fixture", "version": "0.9.17"}), 0],
            ["curl", "localhost:8080/readyz", "", 0],
        ]
        box.set_rules(rules)
        result = box.run([DEV / "swap.sh"], extra)
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertIn("automatic cleanup restored", result.stdout)
        self.assertEqual(env_file.read_bytes(), before_env)
        self.assertEqual(refresh_bin.read_bytes(), before_tools[0])
        self.assertEqual((envlib / "required-env-keys.txt").read_bytes(), before_tools[1])
        self.assertEqual((envlib / "release-env-defaults").read_bytes(), before_tools[2])
        self.assertFalse((deploy_root / "current").exists())
        self.assertFalse((deploy_root / "current").is_symlink())
        self.assertEqual(prior_rollback.read_text(), "prior rollback fixture\n")
        self.assertIn("automatic cleanup status=0", Path(extra["RESULT"]).read_text())

    @requires_gnu_ln
    def test_explicit_rollback_failure_is_single_entry_and_retains_recovery_state(self):
        previous_image = "sha256:" + "c" * 64
        for failure in ("restart", "readiness"):
            with self.subTest(failure=failure):
                box, extra, _ = self.seeded_swap_box()
                state = Path(extra["STATE"])
                state.mkdir()
                prior = state / "rollback-state"
                prior_bytes = b"older rollback record\n"
                prior.write_bytes(prior_bytes)
                prior.chmod(0o600)
                (state / "last-good-image").write_text(previous_image + "\n")
                sleep = box.bin / "sleep"
                sleep.write_text(STUB)
                sleep.chmod(sleep.stat().st_mode | stat.S_IXUSR)
                run_results = [["", 1], ["", 1 if failure == "restart" else 0]]
                rules = dev_host_rules() + [
                    ["psql", "select count", "0\n", 0],
                    ["docker", "^pull", "", 0],
                    ["docker", "image inspect.*image.revision", COMMIT + "\n", 0],
                    ["docker", "image inspect.*image.version", "0.9.17\n", 0],
                    ["docker", "^container inspect coordinator", [["{}\n", 0], ["", 1]], 0],
                    ["docker", "^inspect coordinator --format.*Config.Env",
                     "EIGENINFERENCE_DRAIN_GRACE=45s\n", 0],
                    ["docker", "^inspect --format.*Image.* coordinator", previous_image + "\n", 0],
                    ["docker", "image inspect.*--format.*Id", previous_image + "\n", 0],
                    ["docker", "^ps", "fallback-id\n", 0],
                    ["docker", "^inspect coordinator_fallback_.*Config.Env",
                     "EIGENINFERENCE_DRAIN_GRACE=45s\n", 0],
                    ["docker", "^rename", "", 0],
                    ["docker", "^stop", "", 0],
                    ["docker", "^run", run_results, 0],
                    ["curl", "localhost:8080/health",
                     [[json.dumps({"status": "ok"}) + "\n", 0], ["", 1]], 0],
                    ["sleep", "", "", 0],
                ]
                box.set_rules(rules)
                result = box.run([DEV / "swap.sh"], extra)
                self.assertNotEqual(result.returncode, 0)
                runs = [call for call in box.calls("docker") if call[1] == "run"]
                self.assertEqual(len(runs), 2, runs)
                self.assertNotIn("automatic cleanup restored", result.stdout)
                self.assertNotEqual(prior.read_bytes(), prior_bytes)
                recovery = prior.read_text().splitlines()
                self.assertEqual(len(recovery), 6)
                self.assertEqual(recovery[0], previous_image)
                self.assertIn("recovery context retained", Path(extra["RESULT"]).read_text())

    def test_automatic_cleanup_reports_rollback_command_failure(self):
        box, extra, _ = self.seeded_swap_box()
        rules = dev_host_rules() + [
            ["psql", "select count", "0\n", 0],
            ["docker", "^pull", "", 0],
            ["docker", "image inspect.*image.revision", COMMIT + "\n", 0],
            ["docker", "image inspect.*image.version", "0.9.17\n", 0],
            ["docker", "^container inspect coordinator", [["", 1], ["{}\n", 0]], 0],
            ["docker", "^run", "candidate-container\n", 0],
            ["docker", "^inspect coordinator --format.*Config.Env", "EIGENINFERENCE_DRAIN_GRACE=45s\n", 0],
            ["docker", "^stop", "", 55],
            ["date", r"^\+%s$", [["100\n", 0], ["101\n", 0], ["", 42]], 0],
            ["curl", "localhost:8080/health", json.dumps({"status": "ok", "build_commit": COMMIT,
                                                            "build_date": "fixture", "version": "0.9.17"}), 0],
            ["curl", "localhost:8080/readyz", "", 0],
        ]
        box.set_rules(rules)
        result = box.run([DEV / "swap.sh"], extra)
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertNotIn("automatic cleanup restored", result.stdout)
        self.assertIn("automatic cleanup failed", result.stderr)
        self.assertIn("could not stop coordinator during rollback", Path(extra["RESULT"]).read_text())

    def test_swap_refuses_other_project(self):
        box = Sandbox(self, MUTATORS, dev_host_rules(project="darkbloom-mainnet"))
        result_file = box.root / "result"
        result = box.run([DEV / "swap.sh"], {"LIB": str(ROOT), "RESULT": str(result_file)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not darkbloom-dev", result_file.read_text())
        self.assertEqual([c[0] for c in box.calls()], ["id", "curl"])


if __name__ == "__main__":
    unittest.main()
