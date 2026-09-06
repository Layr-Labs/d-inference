#!/usr/bin/env python3
"""Bounded streaming tests for four production filters; stdlib + Bash + grep only.

Run: python3 scripts/test-signature-stream-checks.py
Only the extracted right-hand grep commands run, never codesign or runtime-smoke.
Each pipeline has a 5-second deadline and streams an 8 MiB nonmatching tail,
well beyond macOS/Linux pipe capacity. No fixture files, builds, or sleeps.
"""

from dataclasses import dataclass
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
QUALIFIER = ROOT / "scripts/qualify-signed-macos-app.sh"
WORKFLOW = ROOT / ".github/workflows/release-swift.yml"
TAIL_BYTES = 8 * 1024 * 1024
TIMEOUT_SECONDS = 5
PRODUCER_FAILURE = 73

# A separate interpreter writes the required line before any padding. Reset
# Python's ignored SIGPIPE so an early reader exit kills this producer exactly
# as it kills codesign. Raw writes avoid Python buffering and handle short writes.
PRODUCER = r"""
import os
import signal
import sys

signal.signal(signal.SIGPIPE, signal.SIG_DFL)

def write_all(data):
    remaining = memoryview(data)
    while remaining:
        remaining = remaining[os.write(1, remaining):]

write_all(sys.argv[1].encode() + b"\n")
block = (b"nonmatching diagnostic padding " + b"." * 992 + b"\n") * 64
remaining = int(sys.argv[3])
while remaining:
    chunk = block[:remaining]
    write_all(chunk)
    remaining -= len(chunk)
os.write(2, ("PRODUCER_DRAINED %s\n" % sys.argv[3]).encode())
sys.exit(int(sys.argv[2]))
"""


@dataclass(frozen=True)
class StreamFilter:
    path: Path
    line: int
    command: str
    matching: str
    missing: str

    @property
    def location(self):
        return f"{self.path.relative_to(ROOT)}:{self.line}"


def extract_filter(path, producer, matching, missing):
    """Anchor to the actual producer; preserve the RHS's quoting and redirects.

    These production sites use a two-line pipeline. Fail explicitly if that
    layout or its producer changes, instead of silently testing a stale copy.
    The qualifier's following `|| fail` belongs to its caller, not the filter.
    """
    text = path.read_text(encoding="utf-8")
    pattern = (r"(?m)^[ \t]*" + re.escape(producer)
               + r"[ \t]+\\\n[ \t]*\|[ \t]*(?P<command>[^\n]+)")
    matches = list(re.finditer(pattern, text))
    if len(matches) != 1:
        raise AssertionError(
            f"{path.relative_to(ROOT)}: expected one pipeline from {producer!r}; "
            f"found {len(matches)}. Update extraction for the real call site."
        )
    match = matches[0]
    command = match["command"].rstrip().removesuffix("\\").rstrip()
    if shlex.split(command)[0] not in ("grep", "/usr/bin/grep"):
        raise AssertionError(f"Unexpected right-hand filter: {command!r}")
    line = text.count("\n", 0, match.start("command")) + 1
    return StreamFilter(path, line, command, matching, missing)


def production_filters():
    filters = [extract_filter(
        QUALIFIER, '/usr/bin/codesign -dvvv "$signed_code" 2>&1',
        "CodeDirectory v=20500 size=4096 flags=0x10000(runtime) hashes=12+7 location=embedded",
        "CodeDirectory v=20500 size=4096 flags=0x0(none) hashes=12+7 location=embedded\n"
        "unrelated diagnostic mentions runtime",
    )]
    for variable in ("PRE_SIGN_SMOKE_OUTPUT", "FINAL_SMOKE_OUTPUT", "ZIP_SMOKE_OUTPUT"):
        filters.append(extract_filter(
            WORKFLOW, "printf '%s\\n' \"$" + variable + '\"',
            "gemma-optimizations-runtime-smoke: ok",
            "prefix gemma-optimizations-runtime-smoke: ok\n"
            "gemma-optimizations-runtime-smoke: ok trailing text",
        ))

    # Check coverage against the source independently of the producer anchors.
    # In particular, do not deduplicate the three identical workflow commands.
    for path, marker in ((QUALIFIER, "CodeDirectory"),
                         (WORKFLOW, "gemma-optimizations-runtime-smoke: ok")):
        sites = {
            number for number, line in enumerate(path.read_text().splitlines(), 1)
            if re.match(r"^[ \t]*\|[ \t]*(?:/usr/bin/)?grep\b", line)
            and marker in line
        }
        covered = {item.line for item in filters if item.path == path}
        if sites != covered:
            raise AssertionError(
                f"{path.relative_to(ROOT)}: production filter lines {sorted(sites)} "
                f"differ from tested lines {sorted(covered)}"
            )
    return tuple(filters)


def run_pipeline(command, first_lines, producer_exit):
    # Capture $? and PIPESTATUS in ONE assignment, before another command
    # resets them. Deliberately omit errexit so failed pipelines can be reported;
    # the shell still exits with the original pipefail status.
    shell = ('"$1" -I -B -c "$2" "$3" "$4" "$5" | ' + command + '\n'
             'statuses=("$?" "${PIPESTATUS[@]}")\n'
             'printf "PIPELINE_STATUS %s %s %s\\n" "${statuses[@]}"\n'
             'exit "${statuses[0]}"\n')
    process = subprocess.Popen(
        ["/bin/bash", "--noprofile", "--norc", "-o", "pipefail", "-c", shell,
         "signature-stream-check", sys.executable, PRODUCER, first_lines,
         str(producer_exit), str(TAIL_BYTES)],
        cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, start_new_session=True,
        # Exclude BASH_ENV, exported functions, GREP_OPTIONS, and Python hooks.
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
    )
    try:
        stdout, stderr = process.communicate(timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        # Killing Bash alone would leave the producer or reader holding pipes.
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=TIMEOUT_SECONDS)
        raise AssertionError(f"Pipeline exceeded {TIMEOUT_SECONDS}s: {command}") from error
    return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)


class SignatureStreamChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.filters = production_filters()
        for item in cls.filters:
            print(f"Testing {item.location}: {item.command}", flush=True)

    def check_pipeline(self, item, *, missing=False, producer_exit=0, quiet=False):
        command = item.command
        if quiet:
            # Regression control only: inject -q into the extracted command in
            # memory. Never edit the qualifier or workflow to simulate failure.
            executable, rest = command.split(maxsplit=1)
            command = f"{executable} -q {rest}"
        result = run_pipeline(command, item.missing if missing else item.matching,
                              producer_exit)
        expected_producer = 128 + signal.SIGPIPE if quiet else producer_exit
        expected_filter = 1 if missing else 0
        expected_pipeline = expected_filter or expected_producer
        details = (f"{item.location}: {command}\nexit={result.returncode}\n"
                   f"stdout={result.stdout!r}\nstderr={result.stderr!r}")
        self.assertEqual(result.returncode, expected_pipeline, details)
        self.assertEqual(
            result.stdout,
            f"PIPELINE_STATUS {expected_pipeline} {expected_producer} {expected_filter}\n",
            details,
        )
        if quiet:
            self.assertNotIn("PRODUCER_DRAINED", result.stderr, details)
        else:
            self.assertEqual(result.stderr, f"PRODUCER_DRAINED {TAIL_BYTES}\n", details)

    def test_successful_matching_producer_is_drained(self):
        for item in self.filters:
            with self.subTest(filter=item.location):
                self.check_pipeline(item)

    def test_missing_required_line_fails_after_draining(self):
        for item in self.filters:
            with self.subTest(filter=item.location):
                self.check_pipeline(item, missing=True)

    def test_matching_output_does_not_hide_producer_failure(self):
        for item in self.filters:
            with self.subTest(filter=item.location):
                self.check_pipeline(item, producer_exit=PRODUCER_FAILURE)

    def test_quiet_negative_control_reproduces_sigpipe(self):
        for item in self.filters:
            with self.subTest(filter=item.location):
                self.check_pipeline(item, quiet=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
