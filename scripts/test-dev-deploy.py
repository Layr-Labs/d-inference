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
import shutil
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
DEV_DEPLOY_WORKFLOW = ROOT / ".github/workflows/dev-deploy-safety.yml"
DEV_DEPLOY_CI_RUNNER = ROOT / "scripts/run-dev-deploy-safety-ci.sh"
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
if name == "psql" and os.environ.get("STUB_EXPECT_PGSSLMODE"):
    if os.environ.get("PGSSLMODE") != os.environ["STUB_EXPECT_PGSSLMODE"]:
        sys.exit(99)
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
if name == "date" and args == ["-u", "+%Y%m%dT%H%M%SZ"]:
    sys.stdout.write("20261007T000000Z\n")
    sys.exit(0)
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


def gnu_publication_tools_available():
    """The remote dev VM publishes with GNU tar and coreutils mv -T."""
    tar_probe = subprocess.run(["tar", "--version"], capture_output=True, text=True)
    mv_probe = subprocess.run(["mv", "--version"], capture_output=True, text=True)
    return (tar_probe.returncode == 0 and "GNU" in tar_probe.stdout and
            mv_probe.returncode == 0 and "GNU" in mv_probe.stdout)


requires_gnu_publication_tools = unittest.skipUnless(
    gnu_publication_tools_available(),
    "publication command uses GNU tar normalization and mv -T on the Ubuntu VM")


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

    def run(self, argv, extra=None, cwd=ROOT, shell="bash"):
        return subprocess.run([shell, *map(str, argv)], env={**self.env, **(extra or {})}, cwd=cwd,
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


def fail_rm_of_env_backups(box):
    """rm fails when an argument contains .bak. and runs the real rm otherwise."""
    rm = box.bin / "rm"
    rm.write_text('#!/bin/sh\ncase "$*" in *.bak.*) exit 55 ;; esac\nexec /bin/rm "$@"\n')
    rm.chmod(0o755)


def lib_with_refresh_wrapper(box, before_refresh="", refresh='exec bash REAL "$@"'):
    """A copy of the shipped deploy files whose prod refresh-env.sh runs the
    shell text before_refresh, then the shell text refresh, in which REAL
    names the real refresh-env.sh."""
    lib = box.root / "lib"
    for name in ("dev", "prod"):
        directory = lib / "deploy/gcp" / name
        directory.mkdir(parents=True)
        for source in (ROOT / "deploy/gcp" / name).iterdir():
            (directory / source.name).symlink_to(source)
    (lib / "deploy/environments").symlink_to(ROOT / "deploy/environments")
    real = ROOT / "deploy/gcp/prod/refresh-env.sh"
    wrapper = lib / "deploy/gcp/prod/refresh-env.sh"
    wrapper.unlink()
    run_refresh = refresh.replace("REAL", f'"{real}"')
    wrapper.write_text(f"#!/bin/bash\nset -euo pipefail\n{before_refresh}\n{run_refresh}\n")
    wrapper.chmod(0o755)
    return lib


def path_filter_matches(pattern, path):
    """GitHub Actions paths filter: ** matches across /, * does not."""
    regex = re.escape(pattern).replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
    return re.fullmatch(regex, path) is not None


class DevEnvContractTests(unittest.TestCase):
    def test_dedicated_workflow_runs_offline_suite_on_supported_platforms(self):
        text = DEV_DEPLOY_WORKFLOW.read_text()
        self.assertIn("permissions:\n  contents: read\n", text)
        self.assertIn("runner: blacksmith-4vcpu-ubuntu-2404", text)
        self.assertIn("runner: blacksmith-12vcpu-macos-27", text)
        self.assertIn('run: scripts/run-dev-deploy-safety-ci.sh "${{ matrix.platform }}"', text)
        runner = DEV_DEPLOY_CI_RUNNER.read_text()
        self.assertIn("pipeline_status=(\"${PIPESTATUS[@]}\")", runner)
        self.assertIn("if ! initial_status=$(git status", runner)
        self.assertIn("if ! find \"$fixture_root\"", runner)
        self.assertIn("persist-credentials: false", text)
        self.assertIn("git status --porcelain --untracked-files=all", runner)
        self.assertIn("Fixture containment:", runner)
        self.assertNotIn("id-token:", text)
        self.assertNotIn("secrets:", text)
        self.assertNotIn("gcloud ", text)

    def test_ci_runner_fails_closed_on_git_tee_and_find_errors(self):
        for failure in ("git", "tee", "find"):
            with self.subTest(failure=failure):
                git_code = 73 if failure == "git" else 0
                box = Sandbox(self, ["git"], [["git", "^status", "", git_code]])
                runner_temp = box.root / "runner"
                runner_temp.mkdir()
                summary = runner_temp / "summary"
                python = box.bin / "python3"
                python.write_text("#!/bin/sh\necho 'Ran 1 test in 0.001s'\necho OK\n")
                python.chmod(0o755)
                if failure == "tee":
                    tee = box.bin / "tee"
                    tee.write_text("#!/bin/sh\ncat >/dev/null\nexit 74\n")
                    tee.chmod(0o755)
                if failure == "find":
                    find = box.bin / "find"
                    find.write_text("#!/bin/sh\nexit 75\n")
                    find.chmod(0o755)
                result = box.run(
                    [DEV_DEPLOY_CI_RUNNER, "fixture"],
                    {"RUNNER_TEMP": str(runner_temp), "GITHUB_STEP_SUMMARY": str(summary)},
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                if failure == "git":
                    self.assertIn("Could not inspect the source tree before tests", result.stderr)
                elif failure == "tee":
                    self.assertIn("Test log capture: failed", summary.read_text())
                else:
                    self.assertIn("Could not inspect temporary fixture containment", result.stderr)

    def test_workflow_paths_are_one_list_that_covers_the_named_suite_inputs(self):
        text = DEV_DEPLOY_WORKFLOW.read_text()
        self.assertEqual(text.count("paths:"), 2)
        self.assertEqual(text.count("    paths: &dev-deploy-safety-paths\n"), 1)
        self.assertEqual(text.count("    paths: *dev-deploy-safety-paths\n"), 1)
        anchored = text.split("    paths: &dev-deploy-safety-paths\n", 1)[1]
        patterns = re.findall(r"^      - (\S+)$", anchored.split("  pull_request:", 1)[0], re.M)
        literals = re.findall(r'ROOT / "([^"]+)"', Path(__file__).read_text())
        inputs = {path for path in literals if (ROOT / path).is_file()}
        for directory in ("deploy/gcp/dev", "deploy/gcp/prod"):
            inputs |= {str(path.relative_to(ROOT)) for path in (ROOT / directory).iterdir()}
        # deploy.sh reads LatestProviderVersion; this file is the suite.
        inputs |= {"coordinator/api/server.go", "scripts/test-dev-deploy.py"}
        uncovered = sorted(path for path in inputs
                           if not any(path_filter_matches(pattern, path) for pattern in patterns))
        self.assertEqual(uncovered, [], "named suite inputs outside the workflow paths filter")

    def test_refresh_backup_contract_has_one_reader(self):
        contract = DEV / "refresh-backup.sh"
        self.assertIn("${2##*backup=}", contract.read_text())
        for script in (SEED, DEV / "swap.sh"):
            text = script.read_text()
            self.assertIn('/refresh-backup.sh" || fail "cannot read ', text, script)
            self.assertNotIn("##*backup=", text, script)
            self.assertNotIn("[0-9]{8}T[0-9]{6}Z", text, script)

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
        self.assertEqual(list(box.env_dir.glob("env.bak.*")), [])
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

    def test_seed_reports_a_kept_refresh_backup_without_failing(self):
        cases = (
            ("removal fails", True, 'exec bash REAL "$@"',
             "REPORT could not remove the redundant post-seed refresh backup"),
            ("output names no backup", False, 'out=$(bash REAL "$@"); printf \'%s\\n\' "${out%%; backup=*}"',
             "REPORT the refresh did not report one regular timestamped backup; nothing removed"),
        )
        for label, fail_rm, refresh, expected in cases:
            with self.subTest(label=label):
                box = self.sandbox()
                if fail_rm:
                    fail_rm_of_env_backups(box)
                seed = lib_with_refresh_wrapper(box, refresh=refresh) / "deploy/gcp/dev/seed-env.sh"
                result = box.run([seed, "--seed"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(expected, result.stdout)
                self.assertIn(f"OK wrote {box.env_dir / 'env'}", result.stdout)
                self.assert_no_value_printed(result)
                self.assertEqual(len(list(box.env_dir.glob("env.bak.*"))), 1)
                rerun = box.run([seed, "--seed"])
                self.assertEqual(rerun.returncode, 0, rerun.stdout + rerun.stderr)
                self.assertIn("nothing to do", rerun.stdout)

    def test_seed_keeps_a_refresh_backup_that_is_not_the_written_file(self):
        box = self.sandbox()
        lib = lib_with_refresh_wrapper(
            box, 'if [ "${1:-}" = --apply ]; then echo CONCURRENT_EDIT=1 >> "$ENV_FILE"; fi')
        result = box.run([lib / "deploy/gcp/dev/seed-env.sh", "--seed"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("is not the file the seed wrote; it is kept", result.stdout)
        self.assert_no_value_printed(result)
        backups = list(box.env_dir.glob("env.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(env_lines(backups[0]).get("CONCURRENT_EDIT"), "1")

    def test_missing_refresh_backup_helper_is_a_named_failure(self):
        box = self.sandbox()
        lib = lib_with_refresh_wrapper(box)
        (lib / "deploy/gcp/dev/refresh-backup.sh").unlink()
        for mode in ("--check", "--seed"):
            with self.subTest(mode=mode):
                result = box.run([lib / "deploy/gcp/dev/seed-env.sh", mode])
                self.assertNotEqual(result.returncode, 0)
                failures = [line for line in (result.stdout + result.stderr).splitlines()
                            if line.startswith("FAIL ")]
                self.assertTrue(any("refresh-backup.sh" in line for line in failures), result.stderr)
                self.assertFalse(box.env_dir.exists())

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

    def host_setup_apply_box(self, caddy_active=True):
        """host-setup.sh --apply on a verified ext4 data disk. A copy of the
        script writes /etc/fstab, the Caddyfile and the env file paths inside
        the sandbox; every command that changes the host is a stub."""
        rules = dev_host_rules() + [
            ["lsblk", "-o TYPE", "disk\n", 0],
            ["lsblk", "-o FSTYPE", "ext4\n", 0],
            ["lsblk", "-o MOUNTPOINTS", "/mnt/disks/userdata\n", 0],
            ["wipefs", "^-n", "ext4\n", 0],
        ]
        if not caddy_active:
            rules.append(["systemctl", "^is-active --quiet caddy$", "", 3])
        box = Sandbox(self, MUTATORS, rules)
        gcp = box.root / "deploy/gcp"
        gcp.mkdir(parents=True)
        for name in ("prod", "dev"):
            (gcp / name).symlink_to(ROOT / "deploy/gcp" / name)
        text = (ROOT / "deploy/gcp/host-setup.sh").read_text()
        box.caddyfile = box.root / "caddy/Caddyfile"
        for old, new in (("/etc/fstab", str(box.root / "fstab")),
                         ("CADDYFILE=/etc/caddy/Caddyfile", f"CADDYFILE={box.caddyfile}"),
                         ("ENV_FILE=/etc/d-inference/env", f"ENV_FILE={box.root / 'env'}")):
            self.assertIn(old, text)
            text = text.replace(old, new)
        self.assertNotIn("/etc/fstab", text)
        box.script = gcp / "host-setup.sh"
        box.script.write_text(text)
        (box.root / "fstab").write_text(
            "/dev/disk/by-id/google-darkbloom-coordinator-data /mnt/disks/userdata ext4 noatime,discard 0 2\n")
        box.caddyfile.parent.mkdir()
        return box

    def caddy_service_calls(self, box):
        return [call[1:] for call in box.calls("systemctl")
                if call[-1] == "caddy" and call[1] not in ("is-active", "is-enabled")]

    def test_host_setup_apply_reloads_caddy_only_when_the_caddyfile_changes(self):
        box = self.host_setup_apply_box()
        box.run([box.script, "--apply"])
        self.assertEqual(self.caddy_service_calls(box), [["enable", "--now", "caddy"], ["reload", "caddy"]])
        self.assertTrue(box.caddyfile.with_name("Caddyfile.new").is_file())

        box.caddyfile.write_text(box.caddyfile.with_name("Caddyfile.new").read_text())
        box.log.write_text("")
        result = box.run([box.script, "--apply"])
        self.assertIn("host setup: --apply done", result.stdout, result.stdout + result.stderr)
        self.assertEqual(self.caddy_service_calls(box), [["enable", "--now", "caddy"]])
        self.assertEqual(box.calls("caddy"), [])

    def test_host_setup_apply_starts_an_inactive_caddy_without_a_reload(self):
        box = self.host_setup_apply_box(caddy_active=False)
        result = box.run([box.script, "--apply"])
        self.assertIn("host setup: --apply done", result.stdout, result.stdout + result.stderr)
        self.assertEqual(self.caddy_service_calls(box), [["enable", "--now", "caddy"]])

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

    def test_required_checks_with_a_failing_conclusion_stop(self):
        for conclusion in (None, "failure", "cancelled", "timed_out", "action_required", "stale",
                           "startup_failure"):
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

    @staticmethod
    def check_runs(conclusions=None, extra=()):
        """The required check runs, all successful unless conclusions names another one."""
        runs = [{"name": name, "status": "completed", "conclusion": (conclusions or {}).get(name, "success")}
                for name in REQUIRED_CHECKS]
        runs += list(extra)
        return json.dumps([{"total_count": len(runs), "check_runs": runs}])

    @staticmethod
    def set_rule(rules, name, pattern, output):
        for rule in rules:
            if rule[0] == name and rule[1] == pattern:
                rule[2] = output
                return
        raise AssertionError(f"no {name} rule {pattern}")

    def full_deploy_rules(self):
        return self.deploy_rules() + [
            ["gcloud", "^compute ssh.*journalctl", f"REPORT fixture\nOK {COMMIT} drain_s=0 start_to_ready_s=1\n", 0],
            ["git", "^archive", "archive", 0],
        ]

    def test_ci_gate_does_not_wait_for_checks_outside_the_required_set(self):
        # deploy-dev.yml runs on the candidate commit, so its own job is an
        # unfinished check run of that commit, as is a long optional workflow.
        rules = self.deploy_rules()
        self.set_rule(rules, "gh", "^api .*check-runs", self.check_runs(extra=[
            {"name": "Deploy dev coordinator", "status": "in_progress", "conclusion": None},
            {"name": "E2E Integration Tests", "status": "queued", "conclusion": None},
        ]))
        box = Sandbox(self, MUTATORS, rules)
        result = box.run([DEV / "deploy.sh", "--dry-run"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("REPORT not required and not finished: Deploy dev coordinator,E2E Integration Tests",
                      result.stdout)
        self.assertIn("REPORT GitHub CI/check contexts are green", result.stdout)
        self.assert_read_only(box)

    def test_ci_gate_waits_for_unfinished_required_checks(self):
        statuses = [{"context": name, "state": "success"} for name in REQUIRED_STATUSES]
        statuses[0]["state"] = "pending"
        early = [{"name": name, "status": "completed", "conclusion": "success"}
                 for name in REQUIRED_CHECKS if name != "Swift Build + Cache"]
        early[2]["status"], early[2]["conclusion"] = "in_progress", None
        rules = self.full_deploy_rules()
        self.set_rule(rules, "gh", "^api .*check-runs", [
            [json.dumps([{"total_count": len(early), "check_runs": early}]), 0], [self.check_runs(), 0]])
        self.set_rule(rules, "gh", "^api .*commits/.*/status", [
            [json.dumps([{"total_count": len(statuses), "statuses": statuses}]), 0],
            [json.dumps([{"total_count": len(statuses), "statuses": [
                {"context": name, "state": "success"} for name in REQUIRED_STATUSES]}]), 0]])
        box = Sandbox(self, MUTATORS + ["sleep"], rules)
        result = box.run([DEV / "deploy.sh"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"waiting for CI: {early[2]['name']},Swift Build + Cache (not reported),"
                      f"{REQUIRED_STATUSES[0]}", result.stdout)
        self.assertEqual(box.calls("sleep"), [["sleep", "15"]])
        self.assertIn(f"OK {COMMIT}", result.stdout)
        self.assertEqual(len([c for c in box.calls("gcloud") if c[1:3] == ["compute", "ssh"]]), 3)

    def test_ci_gate_stops_when_required_checks_do_not_finish_in_time(self):
        rules = self.full_deploy_rules()
        pages = json.loads(self.check_runs())
        for run in pages[0]["check_runs"]:
            if run["name"] == "Coordinator Tests":
                run["status"], run["conclusion"] = "queued", None
        self.set_rule(rules, "gh", "^api .*check-runs", json.dumps(pages))
        box = Sandbox(self, MUTATORS + ["sleep"], rules)
        result = box.run([DEV / "deploy.sh"], {"CI_WAIT_S": "0"})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"CI is not complete for {COMMIT} after 0 s: Coordinator Tests", result.stderr)
        self.assertEqual(box.calls("sleep"), [])
        self.assertEqual([c for c in box.calls("gcloud") if c[1:3] == ["compute", "ssh"]], [])

    def test_skipped_and_neutral_conclusions_are_not_failures(self):
        # ci.yml skips path-gated required jobs, for example the provider lanes
        # on a coordinator-only commit. GitHub branch protection accepts the
        # same three conclusions.
        rules = self.deploy_rules()
        self.set_rule(rules, "gh", "^api .*check-runs", self.check_runs(
            {"Provider Unit Tests": "skipped", "Console UI Lint & Build": "neutral"},
            extra=[{"name": "Landing Lint, Build & Test", "status": "completed", "conclusion": "skipped"}]))
        box = Sandbox(self, MUTATORS, rules)
        result = box.run([DEV / "deploy.sh", "--dry-run"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("REPORT GitHub CI/check contexts are green", result.stdout)
        self.assert_read_only(box)

    def test_unwaived_ci_failure_is_named_under_macos_bash(self):
        # macOS /bin/bash 3.2 treats "${empty[@]}" as unbound under set -u.
        rules = self.deploy_rules()
        self.set_rule(rules, "gh", "^api .*check-runs", self.check_runs({"Coordinator Tests": "failure"}))
        box = Sandbox(self, MUTATORS, rules)
        result = box.run([DEV / "deploy.sh", "--dry-run"], shell="/bin/bash")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CI failure is not explicitly waived: Coordinator Tests", result.stderr)
        self.assertNotIn("unbound variable", result.stderr)

    def test_ci_waiver_audit_names_the_operator(self):
        rules = self.deploy_rules()
        self.set_rule(rules, "gh", "^api .*check-runs", self.check_runs({"Coordinator Tests": "failure"}))
        rules += [["id", "^-un$", "operator\n", 0], ["hostname", "", "workstation\n", 0]]
        box = Sandbox(self, MUTATORS, rules)
        result = box.run([DEV / "deploy.sh", "--dry-run", "--allow-ci-failure", "Coordinator Tests",
                          "--ci-waiver-reason", "owner reviewed base failure"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"REPORT CI waiver for {COMMIT} by dev@example.invalid (operator@workstation): "
                      "owner reviewed base failure", result.stdout)
        self.assertIn("REPORT waived CI failure: Coordinator Tests", result.stdout)
        self.assert_read_only(box)

    def publication(self):
        """The remote publication command of deploy.sh, run locally without
        sudo against sandbox copies of the VM deploy and state directories."""
        box = Sandbox(self, MUTATORS, self.deploy_rules())
        dry_run = box.run([DEV / "deploy.sh", "--dry-run"])
        self.assertEqual(dry_run.returncode, 0, dry_run.stdout + dry_run.stderr)
        marker = "DRY-RUN ssh: /bin/bash -c 'set -euo pipefail\n"
        start = dry_run.stdout.index(marker) + len("DRY-RUN ssh: ")
        end = dry_run.stdout.index("\nDRY-RUN ssh: sudo systemd-run", start)
        command = dry_run.stdout[start:end]

        remote, state = box.root / "remote", box.root / "state"
        command = command.replace("/usr/local/lib/darkbloom-deploy", str(remote))
        command = command.replace("/var/lib/darkbloom-deploy", str(state))
        command = command.replace("sudo ", "")
        archive = subprocess.run(
            ["tar", "-czf", "-", "deploy/gcp/prod", "deploy/gcp/dev",
             "deploy/environments/prod.env"],
            cwd=ROOT, capture_output=True, check=True,
        ).stdout

        def publish(payload=archive, selected_command=command, path_prefix="", env=None):
            return subprocess.run(
                ["bash", "-c", selected_command], input=payload, cwd=ROOT, capture_output=True,
                env={"PATH": path_prefix + os.environ["PATH"], "LC_ALL": "C", **(env or {})},
            )

        return command, archive, publish, remote, state

    @requires_gnu_publication_tools
    def test_candidate_publication_is_atomic_and_same_sha_is_immutable(self):
        command, archive, publish, remote, _ = self.publication()
        first = publish(archive)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        published = remote / COMMIT
        current = remote / "current"
        current.symlink_to(published)
        before = snapshot(published)
        inode = published.stat().st_ino

        repeated = publish(archive)
        self.assertEqual(repeated.returncode, 0, repeated.stdout + repeated.stderr)
        self.assertEqual(published.stat().st_ino, inode)
        self.assertEqual(snapshot(published), before)

        hash_failure = publish(archive, command.replace("sha256sum", "false"))
        self.assertNotEqual(hash_failure.returncode, 0)
        self.assertIn(b"could not hash staged candidate files", hash_failure.stderr)
        self.assertEqual(published.stat().st_ino, inode)
        self.assertEqual(snapshot(published), before)
        self.assertEqual(list(remote.glob(f".incoming-{COMMIT}.*")), [])

        interrupted = publish(archive[:max(1, len(archive) // 2)])
        self.assertNotEqual(interrupted.returncode, 0)
        self.assertTrue(current.is_symlink())
        self.assertEqual(current.resolve(), published.resolve())
        self.assertEqual(published.stat().st_ino, inode)
        self.assertEqual(snapshot(published), before)
        self.assertEqual(list(remote.glob(f".incoming-{COMMIT}.*")), [])

    @requires_gnu_publication_tools
    def test_unused_same_sha_directory_that_differs_is_replaced(self):
        _, _, publish, remote, state = self.publication()
        first = publish()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        published = remote / COMMIT
        exact = snapshot(published)
        (published / "stray").write_text("left by an earlier run\n")
        replaced = publish()
        self.assertEqual(replaced.returncode, 0, replaced.stdout + replaced.stderr)
        self.assertIn(b"REPORT replaced unused published candidate files", replaced.stdout)
        def tree(snap):
            return {path.removeprefix(str(published)): (mode, digest) for path, (mode, _, digest) in snap.items()}
        self.assertEqual(tree(snapshot(published)), tree(exact))
        self.assertFalse((published / "stray").exists())
        self.assertEqual(list(remote.glob(".incoming-*")), [])

        (published / "stray").write_text("left by an earlier run\n")
        changed = snapshot(published)
        current = remote / "current"
        current.symlink_to(published)
        state.mkdir()
        rollback_state = state / "rollback-state"
        for user in ("current", "rollback-state"):
            with self.subTest(user=user):
                if user == "rollback-state":
                    current.unlink()
                    current.symlink_to(remote / "old")
                    rollback_state.write_text(f"none\nx\nx\nx\nx\n{published}\n")
                refused = publish()
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn(b"and current or rollback-state uses them", refused.stderr)
                self.assertEqual(snapshot(published), changed)
                self.assertEqual(list(remote.glob(".incoming-*")), [])

    @requires_gnu_publication_tools
    def test_short_or_unreadable_rollback_state_counts_as_a_use(self):
        _, _, publish, remote, state = self.publication()
        first = publish()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        published = remote / COMMIT
        state.mkdir()
        rollback_state = state / "rollback-state"
        cases = (("empty", "", False), ("five lines", "x\nx\nx\nx\nx\n", False),
                 ("relative line 6", "x\nx\nx\nx\nx\nrelative/path\n", False),
                 ("first deploy", "none\nx\nx\nx\nx\nnone\n", True),
                 ("other directory", f"x\nx\nx\nx\nx\n{remote / ('c' * 40)}\n", True))
        for label, text, replaced in cases:
            with self.subTest(label=label):
                (published / "stray").write_text("left by an earlier run\n")
                rollback_state.write_text(text)
                result = publish()
                if replaced:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse((published / "stray").exists())
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(b"and current or rollback-state uses them", result.stderr)
                    self.assertTrue((published / "stray").exists())
                self.assertEqual(list(remote.glob(".incoming-*")), [])

    @requires_gnu_publication_tools
    def test_failed_publication_rename_restores_or_names_the_old_files(self):
        _, _, publish, remote, _ = self.publication()
        first = publish()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        published = remote / COMMIT
        exact = snapshot(published)
        # mv fails to rename the new tree onto the commit path, and, with
        # FAIL_RESTORE=1, also fails to rename the old tree (it has "stray") back.
        tools = remote.parent / "mv-tools"
        tools.mkdir()
        (tools / "mv").write_text(
            "#!/bin/bash\n"
            f'if [ "$#" -eq 4 ] && [ "$4" = "{published}" ]; then\n'
            '    if [ -e "$3/stray" ]; then [ "${FAIL_RESTORE:-0}" != 1 ] || exit 71\n'
            "    else exit 70; fi\n"
            "fi\n"
            f'exec {shutil.which("mv")} "$@"\n')
        (tools / "mv").chmod(0o755)
        (published / "stray").write_text("left by an earlier run\n")
        changed = snapshot(published)

        restored = publish(path_prefix=f"{tools}{os.pathsep}")
        self.assertNotEqual(restored.returncode, 0)
        self.assertIn(f"restored the old files in {published}".encode(), restored.stderr)
        self.assertEqual(snapshot(published), changed)
        self.assertEqual(list(remote.glob(".incoming-*")), [])

        lost = publish(path_prefix=f"{tools}{os.pathsep}", env={"FAIL_RESTORE": "1"})
        self.assertNotEqual(lost.returncode, 0)
        self.assertFalse(published.exists())
        asides = list(remote.glob(f".incoming-{COMMIT}.*"))
        self.assertEqual(len(asides), 1)
        self.assertTrue((asides[0] / "stray").exists())
        self.assertIn(f"could not publish {published} or restore it: the old files are in {asides[0]}".encode(),
                      lost.stderr)

        recovered = publish()
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        def tree(snap, root):
            return {path.removeprefix(str(root)): (mode, digest) for path, (mode, _, digest) in snap.items()}
        self.assertEqual(tree(snapshot(published), published), tree(exact, published))

    @requires_gnu_publication_tools
    def test_publication_removes_stale_hidden_stage_directories(self):
        _, _, publish, remote, _ = self.publication()
        remote.mkdir()
        stale = remote / f".incoming-{'c' * 40}.Ab12Cd"
        fresh = remote / f".incoming-{'d' * 40}.Ef34Gh"
        operator = remote / ".incoming-notes"
        for directory in (stale, fresh, operator):
            directory.mkdir()
            (directory / "file").write_text("partial extract\n")
        for directory in (stale, operator):
            os.utime(directory, (1, 1))
        result = publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.exists())
        self.assertTrue(operator.exists())
        self.assertTrue((remote / COMMIT).is_dir())

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

    def candidate_swap_rules(self, commit, digest, candidate_image_id, current_image=None):
        candidate = f"us-east4-docker.pkg.dev/darkbloom-dev/coordinator/coordinator@{digest}"
        rules = dev_host_rules() + [
            ["psql", "select count", "0\n", 0],
            ["docker", "^pull", "", 0],
            ["docker", "image inspect.*image.revision", commit + "\n", 0],
            ["docker", "image inspect.*image.version", "0.9.17\n", 0],
            ["date", r"^\+%s$", "100\n", 0],
            ["curl", "localhost:8080/health", json.dumps({
                "status": "ok", "build_commit": commit,
                "build_date": "fixture", "version": "0.9.17",
            }), 0],
            ["curl", "localhost:8080/readyz", "", 0],
            ["curl", "localhost:8080/v1/cache/status", json.dumps({
                "routing_mode": "off", "activation": {"percent": 1, "max_plan_qps": 1},
                "sidecar": {}, "preload": {}, "prompt_artifacts": {},
            }), 0],
            ["docker", "^run", "container-id\n", 0],
            ["docker", r"^inspect --format \{\{\.Config\.Image\}\} coordinator", candidate + "\n", 0],
            ["docker", "^logs", "", 0],
            ["docker", "^ps -a", "", 0],
            ["docker", "^image prune", "", 0],
        ]
        if current_image is None:
            rules += [
                ["docker", "^container inspect coordinator", "", 1],
                ["docker", r"^inspect --format \{\{\.Image\}\} coordinator", candidate_image_id + "\n", 0],
            ]
        else:
            rules += [
                ["docker", "^container inspect coordinator", "{}\n", 0],
                ["docker", "^inspect coordinator --format.*Config.Env", "EIGENINFERENCE_DRAIN_GRACE=45s\n", 0],
                ["docker", r"^inspect --format \{\{\.Image\}\} coordinator",
                 [[current_image + "\n", 0], [candidate_image_id + "\n", 0]], 0],
                ["docker", "^rename", "", 0],
                ["docker", "^stop", "", 0],
            ]
        return rules

    @requires_gnu_ln
    def test_first_second_deploy_rollback_and_second_refusal(self):
        first_commit, second_commit = "a" * 40, "d" * 40
        first_digest, second_digest = "sha256:" + "b" * 64, "sha256:" + "f" * 64
        first_image_id, second_image_id = "sha256:" + "1" * 64, "sha256:" + "2" * 64
        box, extra, paths = self.seeded_swap_box(with_current=False)
        _, _, deploy_root = paths
        first_lib, second_lib = deploy_root / first_commit, deploy_root / second_commit
        first_lib.mkdir()
        (first_lib / "deploy").symlink_to(ROOT / "deploy")

        extra.update({"LIB": str(first_lib), "CANDIDATE_COMMIT": first_commit,
                      "CANDIDATE_DIGEST": first_digest})
        box.set_rules(self.candidate_swap_rules(first_commit, first_digest, first_image_id))
        first = box.run([DEV / "swap.sh"], extra)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        state = Path(extra["STATE"])
        self.assertEqual((deploy_root / "current").resolve(), first_lib.resolve())
        self.assertEqual((state / "last-good-image").read_text().strip(), first_image_id)
        first_record = (state / "rollback-state").read_text().splitlines()
        self.assertEqual(first_record[0], "none")

        second_lib.mkdir()
        (second_lib / "deploy").symlink_to(ROOT / "deploy")
        extra.update({"LIB": str(second_lib), "RESULT": str(box.root / "second.result"),
                      "CANDIDATE_COMMIT": second_commit, "CANDIDATE_DIGEST": second_digest})
        box.log.write_text("")
        box.set_rules(self.candidate_swap_rules(
            second_commit, second_digest, second_image_id, first_image_id))
        second = box.run([DEV / "swap.sh"], extra)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual((deploy_root / "current").resolve(), second_lib.resolve())
        self.assertEqual((state / "last-good-image").read_text().strip(), second_image_id)
        second_record = (state / "rollback-state").read_text().splitlines()
        self.assertEqual(second_record[0], first_image_id)
        self.assertEqual(Path(second_record[5]).resolve(), first_lib.resolve())
        self.assertFalse(Path(first_record[4]).exists())
        self.assertTrue(Path(second_record[4]).exists())

        box.log.write_text("")
        box.set_rules(dev_host_rules() + [
            ["docker", "image inspect.*--format.*Id", first_image_id + "\n", 0],
            ["docker", "^container inspect coordinator", "{}\n", 0],
            ["docker", "^inspect coordinator --format.*Config.Env", "EIGENINFERENCE_DRAIN_GRACE=45s\n", 0],
            ["docker", "^stop", "", 0], ["docker", "^rm coordinator", "", 0],
            ["docker", "^ps -q", "", 0], ["docker", "^run", "rollback-container\n", 0],
            ["docker", "image inspect.*image.revision", first_commit + "\n", 0],
            ["curl", "localhost:8080/health", json.dumps({
                "status": "ok", "build_commit": first_commit,
                "build_date": "fixture", "version": "0.9.17",
            }), 0],
            ["curl", "localhost:8080/readyz", "", 0],
            ["docker", r"^inspect --format \{\{\.Image\}\} coordinator", first_image_id + "\n", 0],
        ])
        rollback_extra = {**extra, "MODE": "rollback", "LIB": str(second_lib),
                          "RESULT": str(box.root / "rollback.result")}
        rollback = box.run([DEV / "swap.sh"], rollback_extra)
        self.assertEqual(rollback.returncode, 0, rollback.stdout + rollback.stderr)
        self.assertEqual((deploy_root / "current").resolve(), first_lib.resolve())
        self.assertEqual((state / "last-good-image").read_text().strip(), first_image_id)
        restored_record = (state / "rollback-state").read_text().splitlines()
        self.assertEqual(restored_record, first_record)
        self.assertFalse(Path(restored_record[4]).exists())

        box.log.write_text("")
        second_rollback = box.run(
            [DEV / "swap.sh"], {**rollback_extra, "RESULT": str(box.root / "second-rollback.result")})
        self.assertNotEqual(second_rollback.returncode, 0)
        self.assertIn("tooling backup is not a root:root 0700 directory",
                      (box.root / "second-rollback.result").read_text())
        self.assertEqual(box.calls("docker"), [])

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
        # The stub answers every call of the command; a stubbed mktemp returns an
        # empty path, so run from the sandbox to keep any relative write inside it.
        result = box.run([DEV / "swap.sh"], extra, cwd=box.root)
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

    @staticmethod
    def first_deploy_rules():
        """A first deploy (no coordinator container) that passes every gate."""
        image = f"us-east4-docker.pkg.dev/darkbloom-dev/coordinator/coordinator@{DIGEST}"
        return dev_host_rules() + [
            ["psql", "select count", "0\n", 0],
            ["docker", "^pull", "", 0],
            ["docker", "image inspect.*image.revision", COMMIT + "\n", 0],
            ["docker", "image inspect.*image.version", "0.9.17\n", 0],
            ["docker", "^container inspect coordinator", "", 1],
            ["docker", "^run", "candidate-container\n", 0],
            ["docker", r"^inspect --format \{\{\.Config\.Image\}\} coordinator", image + "\n", 0],
            ["docker", r"^inspect --format \{\{\.Image\}\} coordinator", "sha256:" + "e" * 64 + "\n", 0],
            ["date", r"^\+%s$", "100\n", 0],
            ["curl", "localhost:8080/health", json.dumps({"status": "ok", "build_commit": COMMIT,
                                                            "build_date": "fixture", "version": "0.9.17"}), 0],
            ["curl", "localhost:8080/readyz", "", 0],
        ]

    def test_refresh_backup_that_differs_from_the_snapshot_is_kept(self):
        # An env edit between the env.before snapshot and the refresh is only
        # in the refresh backup. The restore must not remove that copy.
        box, extra, _ = self.seeded_swap_box(with_current=False)
        lib = lib_with_refresh_wrapper(
            box, 'if [ "${1:-}" = --apply ]; then echo CONCURRENT_EDIT=1 >> "$ENV_FILE"; fi')
        env_file = Path(extra["ENV_FILE"])
        before = env_file.read_bytes()
        box.set_rules(self.first_deploy_rules())
        result = box.run([lib / "deploy/gcp/dev/swap.sh"], {**extra, "LIB": str(lib)})
        self.assertNotEqual(result.returncode, 0)
        result_line = Path(extra["RESULT"]).read_text()
        self.assertIn("does not match the pre-refresh env and is kept", result_line)
        self.assertEqual(env_file.read_bytes(), before)
        backups = list(env_file.parent.glob("env.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(env_lines(backups[0]).get("CONCURRENT_EDIT"), "1")
        self.assertNotIn("fixture-password", result.stdout + result.stderr + result_line)

    def test_failed_refresh_backup_removal_restores_the_prior_rollback_state(self):
        box, extra, _ = self.seeded_swap_box(with_current=False)
        state = Path(extra["STATE"])
        state.mkdir()
        prior = state / "rollback-state"
        prior.write_text("prior rollback fixture\n")
        prior.chmod(0o600)
        env_file = Path(extra["ENV_FILE"])
        before = env_file.read_bytes()
        fail_rm_of_env_backups(box)
        box.set_rules(self.first_deploy_rules())
        result = box.run([DEV / "swap.sh"], extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(Path(extra["RESULT"]).read_text().strip(),
                         "FAIL could not remove the redundant refresh backup; "
                         "restored the pre-deploy env, tooling and current link")
        self.assertEqual(prior.read_text(), "prior rollback fixture\n")
        self.assertEqual(env_file.read_bytes(), before)
        self.assertNotIn("automatic cleanup", result.stdout + result.stderr)
        self.assertEqual([call for call in box.calls("docker") if call[1] == "run"], [])

    def test_swap_names_a_missing_refresh_backup_helper(self):
        box, extra, _ = self.seeded_swap_box()
        lib = lib_with_refresh_wrapper(box)
        (lib / "deploy/gcp/dev/refresh-backup.sh").unlink()
        box.set_rules(self.first_deploy_rules())
        result = box.run([lib / "deploy/gcp/dev/swap.sh"], {**extra, "LIB": str(lib)})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(Path(extra["RESULT"]).read_text().strip(),
                         f"FAIL cannot read {lib}/deploy/gcp/dev/refresh-backup.sh; nothing changed")
        self.assertEqual(box.calls("psql"), [])
        self.assertEqual(box.calls("docker"), [])

    @requires_gnu_ln
    def test_committed_deploy_keeps_an_env_backup_that_only_env_before_matches(self):
        # The candidate adds a release default, so the live file changes. A
        # backup of the pre-deploy env is then the same as env.before only,
        # which the next deploy removes with its attempt directory.
        box, extra, _ = self.seeded_swap_box(with_current=False)
        lib = lib_with_refresh_wrapper(box)
        defaults = lib / "deploy/gcp/prod/release-env-defaults"
        defaults.unlink()
        defaults.write_text(DEFAULTS.read_text() + "EIGENINFERENCE_FIXTURE_NEW_DEFAULT=1\n")
        env_file = Path(extra["ENV_FILE"])
        pre_deploy = env_file.parent / "env.bak.20200101T000000Z"
        pre_deploy.write_bytes(env_file.read_bytes())
        box.set_rules(self.first_deploy_rules())
        result = box.run([lib / "deploy/gcp/dev/swap.sh"], {**extra, "LIB": str(lib)})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(Path(extra["RESULT"]).read_text().startswith(f"OK {COMMIT} "))
        self.assertEqual(env_lines(env_file).get("EIGENINFERENCE_FIXTURE_NEW_DEFAULT"), "1")
        self.assertTrue(pre_deploy.exists())

    @requires_gnu_ln
    def test_committed_deploy_removes_only_redundant_env_backups(self):
        box, extra, _ = self.seeded_swap_box(with_current=False)
        env_file = Path(extra["ENV_FILE"])
        redundant = env_file.parent / "env.bak.20200101T000000Z"
        unique = env_file.parent / "env.bak.20200102T000000Z"
        lookalike = env_file.parent / "env.bak.operator"
        redundant.write_bytes(env_file.read_bytes())
        unique.write_bytes(env_file.read_bytes() + b"BOOT_ONLY_STATE=1\n")
        lookalike.write_bytes(env_file.read_bytes())
        box.set_rules(self.first_deploy_rules())
        result = box.run([DEV / "swap.sh"], extra)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(Path(extra["RESULT"]).read_text().startswith(f"OK {COMMIT} "))
        self.assertFalse(redundant.exists())
        self.assertTrue(unique.exists())
        self.assertTrue(lookalike.exists())
        self.assertEqual(sorted(env_file.parent.glob("env.bak.*")), sorted([lookalike, unique]))

    @requires_gnu_ln
    def test_committed_deploy_survives_a_credential_cleanup_failure(self):
        box, extra, paths = self.seeded_swap_box(with_current=False)
        _, _, deploy_root = paths
        path = box.bin / "rm"
        path.write_text(STUB)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        box.set_rules(self.first_deploy_rules() + [["rm", "\\.pg\\.", "", 55]])
        result = box.run([DEV / "swap.sh"], extra)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result_line = Path(extra["RESULT"]).read_text()
        self.assertTrue(result_line.startswith(f"OK {COMMIT} "), result_line)
        self.assertIn("private database credential cleanup failed", result_line)
        self.assertIn("private database credential cleanup failed", result.stderr)
        self.assertNotIn("automatic cleanup", result.stdout + result.stderr)
        self.assertEqual(len([call for call in box.calls("docker") if call[1] == "run"]), 1)
        self.assertEqual([call for call in box.calls("docker") if call[1] == "stop"], [])
        self.assertEqual((deploy_root / "current").resolve(), ROOT.resolve())
        self.assertNotIn("fixture-password", result.stdout + result.stderr + result_line)

    @requires_gnu_ln
    def test_committed_deploy_keeps_only_the_files_one_rollback_reads(self):
        box, extra, paths = self.seeded_swap_box()
        _, _, deploy_root = paths
        previous = deploy_root / ("c" * 40)
        previous.mkdir()
        (deploy_root / "current").unlink()
        (deploy_root / "current").symlink_to(previous)
        superseded = deploy_root / ("d" * 40)
        superseded.mkdir()
        (superseded / "file").write_text("superseded deploy files\n")
        lib = deploy_root / COMMIT
        lib.mkdir()
        (lib / "deploy").symlink_to(ROOT / "deploy")
        unit_result = deploy_root / "darkbloom-dev-swap-aaaaaaa-1.result"
        unit_result.write_text("OK fixture\n")
        aged_result = deploy_root / "darkbloom-dev-swap-bbbbbbb-2.result"
        aged_result.write_text("old generated result\n")
        os.utime(aged_result, (1, 1))
        lookalike_result = deploy_root / "darkbloom-dev-swap-old-1.result"
        lookalike_result.write_text("operator lookalike\n")
        newline_result = deploy_root / "darkbloom-dev-swap-ccccccc-3.result\noperator"
        newline_result.write_text("operator newline name\n")
        nondigit_result = deploy_root / "darkbloom-dev-swap-abcdef0-1x.result"
        nondigit_result.write_text("operator lookalike\n")
        aged_rollback = deploy_root / "darkbloom-dev-rollback-123.result"
        aged_rollback.write_text("old generated result\n")
        rollback_lookalike = deploy_root / "darkbloom-dev-rollback-12a.result"
        rollback_lookalike.write_text("operator lookalike\n")
        for path in (lookalike_result, newline_result, nondigit_result, aged_rollback, rollback_lookalike):
            os.utime(path, (1, 1))
        state = Path(extra["STATE"])
        state.mkdir()
        aged_log = state / "failed-coordinator-20200101T000000Z.log"
        aged_log.write_text("old generated log\n")
        log_lookalike = state / "failed-coordinator-2020.log"
        log_lookalike.write_text("operator lookalike\n")
        os.utime(log_lookalike, (1, 1))
        operator_file = state / "operator-note.log"
        operator_file.write_text("preserve me\n")
        os.utime(aged_log, (1, 1))
        os.utime(operator_file, (1, 1))
        old_attempt = state / "attempt-20200101T000000Z-1"
        old_attempt.mkdir(mode=0o700)
        (old_attempt / "env.before").write_text("SECRET-FIXTURE-VALUE\n")
        extra["LIB"] = str(lib)
        box.set_rules(self.first_deploy_rules())
        result = box.run([DEV / "swap.sh"], extra)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(Path(extra["RESULT"]).read_text().startswith(f"OK {COMMIT} "))
        self.assertEqual(list(Path(extra["ENV_FILE"]).parent.glob("env.bak.*")), [])
        record = (state / "rollback-state").read_text().splitlines()
        self.assertEqual(len(record), 6)
        self.assertEqual(sorted(state.glob("attempt-*")), [Path(record[4])])
        self.assertTrue(Path(record[1]).is_file())
        self.assertEqual(record[5], str(previous))
        self.assertFalse(old_attempt.exists())
        self.assertFalse(superseded.exists())
        self.assertFalse(aged_result.exists())
        self.assertTrue(lookalike_result.exists())
        self.assertTrue(newline_result.exists())
        self.assertTrue(nondigit_result.exists())
        self.assertFalse(aged_rollback.exists())
        self.assertTrue(rollback_lookalike.exists())
        self.assertFalse(aged_log.exists())
        self.assertTrue(operator_file.exists())
        self.assertTrue(log_lookalike.exists())
        for kept in (previous, lib, unit_result, deploy_root / "old"):
            self.assertTrue(kept.exists(), kept)
        self.assertEqual((deploy_root / "current").resolve(), lib.resolve())

    @requires_gnu_ln
    def test_generated_history_find_failure_is_reported_after_commit(self):
        box, extra, _ = self.seeded_swap_box(with_current=False)
        find = box.bin / "find"
        find.write_text(STUB)
        find.chmod(0o755)
        box.set_rules(self.first_deploy_rules() + [["find", "", "", 76]])
        result = box.run([DEV / "swap.sh"], extra)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("could not remove every dev deploy result or failed-container log",
                      result.stderr)
        self.assertTrue(Path(extra["RESULT"]).read_text().startswith(f"OK {COMMIT} "))

    def test_swap_requires_a_tls_single_host_database_url(self):
        box, extra, _ = self.seeded_swap_box()
        env_file = Path(extra["ENV_FILE"])
        seeded = env_file.read_text()
        base = "postgresql://coordinator:fixture-password@192.0.2.5:5432/eigeninference"
        accepted = {
            "?sslmode=require": "require",
            "?sslmode=verify-ca": "verify-ca",
            "?connect_timeout=10&sslmode=verify-full&sslrootcert=/mnt/disks/userdata/server-ca.pem": "verify-full",
        }
        rejected = ("", "?sslmode=prefer", "?sslmode=disable", "?sslmode=allow", "?sslmode=",
                    "?sslmode=require&sslmode=disable", "?sslmode=require&host=203.0.113.9",
                    "?sslmode=require&hostaddr=203.0.113.9", "?sslmode=require&port=6432",
                    "?sslmode=require&dbname=other", "?sslmode=require&user=other",
                    "?sslmode=require&service=other", "?sslmode=require&sslrootcert=a%09b")
        # A connection that passes TLS selection reaches db_clear, which reports a long query.
        box.set_rules(dev_host_rules() + [["psql", "select 1", "1\n", 0], ["psql", "select count", "1\n", 0]])
        for query in [*accepted, *rejected]:
            with self.subTest(query=query):
                env_file.write_text(seeded.replace(f"{base}?sslmode=require", base + query))
                box.log.write_text("")
                mode = accepted.get(query)
                result = box.run([DEV / "swap.sh"], {**extra, "STUB_EXPECT_PGSSLMODE": mode or "unused"})
                self.assertNotEqual(result.returncode, 0)
                result_line = Path(extra["RESULT"]).read_text()
                if mode:
                    self.assertIn("long queries", result_line)
                else:
                    self.assertIn("EIGENINFERENCE_DATABASE_URL is not", result_line)
                    self.assertEqual(box.calls("psql"), [])
                self.assertNotIn("fixture-password", result.stdout + result.stderr + result_line)
                self.assertEqual(list(Path(extra["STATE"]).glob(".pg.*")), [])

    def test_swap_refuses_other_project(self):
        box = Sandbox(self, MUTATORS, dev_host_rules(project="darkbloom-mainnet"))
        result_file = box.root / "result"
        result = box.run([DEV / "swap.sh"], {"LIB": str(ROOT), "RESULT": str(result_file)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not darkbloom-dev", result_file.read_text())
        self.assertEqual([c[0] for c in box.calls()], ["id", "curl"])


if __name__ == "__main__":
    unittest.main()
