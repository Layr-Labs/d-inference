#!/usr/bin/env python3
"""Run a CI command in the background of a job, and wait for its result in a later step.

The provider build job builds the matched Metal library beside the Swift
build (.github/actions/provider-ci-build): the library needs only the MLX
sources and the toolchain, and much of the Swift build waits on SwiftPM's
fetches and its last links, not on the CPU.

  start DIRECTORY COMMAND...  start COMMAND in its own session; it writes its
                              output to DIRECTORY/output.log and, when it
                              ends, its exit status to DIRECTORY/status
  wait DIRECTORY              wait for the status, print the output, and fail
                              unless the command succeeded or after LIMIT_SECONDS

The command runs in a session of its own, as the resource sampler does, so it
outlives the step that started it. The job's end stops what is still running.
"""

import argparse
from pathlib import Path
import shlex
import subprocess
import sys
import time


LIMIT_SECONDS = 30 * 60
POLL_SECONDS = 1.0
# Written only when the command has ended: the shell writes a temporary file
# and renames it, so `wait` never reads a partial status.
RECORD = 'cd "$1" && shift && "$@" > "$0/output.log" 2>&1; echo $? > "$0/status.tmp" && mv "$0/status.tmp" "$0/status"'


def start(directory, command, cwd=None):
    directory.mkdir(parents=True, exist_ok=False)
    process = subprocess.Popen(["bash", "-c", RECORD, str(directory.resolve()), str(Path(cwd or Path.cwd()).resolve()),
                                *command],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    print(f"Started {shlex.join(command)} (pid {process.pid}); output in {directory / 'output.log'}")
    return process


def show_output(directory):
    print("::group::Output of the background command")
    output = directory / "output.log"
    text = output.read_text(errors="replace") if output.exists() else "(no output file)\n"
    # A command stopped mid-line must not swallow the group's end marker.
    sys.stdout.write(text if text.endswith("\n") or not text else text + "\n")
    print("::endgroup::", flush=True)


def wait(directory, limit=LIMIT_SECONDS, poll=POLL_SECONDS, clock=time.monotonic, sleep=time.sleep):
    """Return the command's exit status once it has ended; raise TimeoutError after limit seconds.

    Either way it prints the command's output, so far as it got.
    """
    status = directory / "status"
    started = clock()
    while not status.exists():
        if clock() - started >= limit:
            show_output(directory)
            raise TimeoutError(f"The background command in {directory} had not ended after {limit:.0f} s")
        sleep(poll)
    code = int(status.read_text().strip())
    print(f"The background command ended with status {code}; this step waited {clock() - started:.0f} s for it.")
    show_output(directory)
    return code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="action", required=True)
    starter = commands.add_parser("start")
    starter.add_argument("directory", type=Path)
    starter.add_argument("command", nargs=argparse.REMAINDER)
    commands.add_parser("wait").add_argument("directory", type=Path)
    args = parser.parse_args(argv)
    if args.action == "start":
        if not args.command:
            parser.error("start needs a command")
        start(args.directory, args.command)
        return 0
    try:
        code = wait(args.directory)
    except TimeoutError as error:
        print(f"::error title=Background command::{error}")
        return 1
    if code:
        print(f"::error title=Background command::The background command failed with status {code}; see its output above.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
