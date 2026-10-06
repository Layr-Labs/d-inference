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
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEV = ROOT / "deploy/gcp/dev"
SEED = DEV / "seed-env.sh"
OVERRIDES = DEV / "env-overrides"
REQUIRED = ROOT / "deploy/gcp/prod/required-env-keys.txt"
DEFAULTS = ROOT / "deploy/gcp/prod/release-env-defaults"
WORKFLOW = ROOT / ".github/workflows/deploy-dev.yml"
PROD_ENV = ROOT / "deploy/environments/prod.env"
COMMIT = "a" * 40
DIGEST = "sha256:" + "b" * 64

# A stub reads its rules from STUB_RULES: [name, regex over the joined
# arguments, stdout, exit code]. The first matching rule wins; no match prints
# nothing and exits 0. Every call is appended to STUB_LOG.
STUB = r'''#!/usr/bin/env python3
import json, os, re, sys
name = os.path.basename(sys.argv[0])
args = sys.argv[1:]
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(json.dumps([name] + args) + "\n")
if name == "gcloud" and args[:2] == ["compute", "ssh"] and not any(a == "--command=true" for a in args):
    sys.stdin.read()
for rule_name, pattern, out, code in json.load(open(os.environ["STUB_RULES"])):
    if rule_name == name and re.search(pattern, " ".join(args)):
        sys.stdout.write(out)
        sys.exit(code)
'''

# Every command that the scripts can use to change state. Read-only tools
# (awk, grep, sed, cmp, find, sort, jq) stay real.
MUTATORS = ["apt-get", "blkid", "caddy", "chmod", "chown", "cp", "dd", "docker", "dpkg", "gcloud",
            "gpg", "install", "ln", "mkdir", "mkfs.ext4", "mount", "mountpoint", "mv", "psql",
            "pg_isready", "rm", "sudo", "systemctl", "systemd-run", "tee", "usermod", "findmnt",
            "curl", "id", "dig", "git", "gh", "hostname"]


class Sandbox:
    def __init__(self, testcase, stubs, rules):
        tmp = tempfile.TemporaryDirectory()
        testcase.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.log.touch()
        self.rules_file = self.root / "rules.json"
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
            "SKIP_PERSISTENCE_CHECK": "1",
            "LC_ALL": "C",
        }
        (self.root / "home").mkdir()

    def set_rules(self, rules):
        self.rules_file.write_text(json.dumps(rules))

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
        files = [*DEV.glob("*.sh"), ROOT / "deploy/gcp/host-setup.sh", ROOT / "scripts/smoke-dev.sh", WORKFLOW]
        for path in files:
            self.assertNotIn(api, path.read_text(), path)
            self.assertNotIn(console.removeprefix("https://"), path.read_text(), path)
        self.assertEqual(OVERRIDES.read_text().count(api), 1)
        self.assertEqual(OVERRIDES.read_text().count(console.removeprefix("https://")), 1)


class SeedEnvTests(unittest.TestCase):
    def sandbox(self, **rules):
        box = Sandbox(self, ["id", "curl", "gcloud"], dev_host_rules(**rules))
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
    if name in ("id", "dig", "findmnt", "pg_isready", "hostname"):
        return True
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
        return args[:2] == ["variable", "get"]
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
        return [
            ["gh", "^variable get DEV_DEPLOY_PAUSED", paused, paused_code],
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
            self.assertIn("REPORT DEV_DEPLOY_PAUSED=true (from gh variable get)", result.stdout)
        self.assertEqual(out.read_text(), "deployed=false\ndeployed=false\n")
        result = box.run([DEV / "deploy.sh"], {"DEV_DEPLOY_PAUSED": "true"})
        self.assert_paused_refusal(box, result)
        self.assertIn("REPORT DEV_DEPLOY_PAUSED=true (from environment)", result.stdout)

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

    def test_swap_refuses_other_project(self):
        box = Sandbox(self, MUTATORS, dev_host_rules(project="darkbloom-mainnet"))
        result_file = box.root / "result"
        result = box.run([DEV / "swap.sh"], {"LIB": str(ROOT), "RESULT": str(result_file)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not darkbloom-dev", result_file.read_text())
        self.assertEqual([c[0] for c in box.calls()], ["id", "curl"])



class DeployWorkflowTests(unittest.TestCase):
    """deploy-dev.yml leaves the pause decision to deploy.sh on every run."""

    def setUp(self):
        self.text = WORKFLOW.read_text()

    def test_workflow_never_overrides_the_pause(self):
        self.assertFalse("--override-pause" in self.text, "deploy-dev.yml names --override-pause")

    def test_deploy_step_passes_the_pause_variable(self):
        step = self.text.split("        id: deploy\n", 1)[1].split("\n      - ", 1)[0]
        self.assertIn("deploy/gcp/dev/deploy.sh", step)
        self.assertIn("          DEV_DEPLOY_PAUSED: ${{ vars.DEV_DEPLOY_PAUSED }}\n", step)

    def test_token_subject_rules_of_the_wif_provider(self):
        for banned in ("environment:", "pull_request", "secrets."):
            self.assertFalse(banned in self.text, f"deploy-dev.yml has {banned}")


if __name__ == "__main__":
    unittest.main()
