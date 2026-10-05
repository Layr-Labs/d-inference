"""Run isolated test shards alongside the remaining, unsharded Go packages."""

import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import threading
import time

from .results import merge_coverage, partition, test_names, verify_events

ROOT = Path(__file__).resolve().parents[2]
COORDINATOR = "github.com/eigeninference/d-inference/coordinator"
API = COORDINATOR + "/tests/api"
REGISTRY = COORDINATOR + "/tests/registry"
API_SHARDS = (API, API + "/inference", API + "/inference/contracts",
              API + "/provider/trust", API + "/provider/contracts")


class Processes:
    """Own process groups so interrupting the runner also stops test binaries."""

    def __init__(self):
        self.lock = threading.RLock()
        self.children = set()
        self.cancelled = False
        self.interrupted = False

    def start(self, command, **kwargs):
        with self.lock:
            if self.cancelled:
                raise InterruptedError("test run interrupted")
            process = subprocess.Popen(command, start_new_session=True, **kwargs)
            self.children.add(process)
            # A signal can arrive on the main thread during Popen, before the
            # new process was visible to cancel(). Do not orphan that child.
            if self.cancelled:
                self.cancel()
            return process

    def finish(self, process):
        with self.lock:
            self.children.discard(process)

    def cancel(self):
        with self.lock:
            self.cancelled = True
            for process in self.children:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    # The child already exited, so its process group is gone.
                    pass


def checked_output(command, cwd, processes, env=None):
    process = processes.start(command, cwd=cwd, stdout=subprocess.PIPE, text=True, env=env)
    try:
        output, _ = process.communicate(timeout=600)
        if process.returncode:
            print(output, flush=True)
            raise subprocess.CalledProcessError(process.returncode, command)
        return output
    except BaseException:
        processes.cancel()
        process.wait()
        raise
    finally:
        processes.finish(process)


def run_task(label, command, cwd, output, expected, processes, packages=None):
    started = time.monotonic()
    log = output / f"{label}.jsonl"
    errors = output / f"{label}.stderr"
    result = {"task": label, "command": command}
    with log.open("w") as stdout, errors.open("w") as stderr:
        process = processes.start(command, cwd=cwd, stdout=stdout, stderr=stderr)
        try:
            # The aggregate retains Go's per-package timeout, not a suite cutoff.
            code = process.wait(timeout=660 if expected is not None else None)
        except BaseException:
            processes.cancel()
            process.wait()
            raise
        finally:
            processes.finish(process)
    result["seconds"] = round(time.monotonic() - started, 3)
    try:
        if code != 0:
            raise ValueError(f"command exited {code}")
        result["tests"] = verify_events(log, expected, packages)
        result["passed"] = True
    except (ValueError, OSError) as error:
        result.update(passed=False, error=str(error))
    return result


def positive(value):
    value = int(value)
    if value < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def run(args, output, processes):
    packages = checked_output(["go", "list", *args.packages], ROOT, processes).splitlines()
    packages = list(dict.fromkeys(packages))
    if not packages:
        raise ValueError("no Go packages selected")
    flags = ["-race"] if args.race else []
    if args.coverprofile:
        # Contract suites live outside their implementations. Instrument the
        # same production packages in every binary so their imported behavior
        # remains covered and overlapping profiles have identical counters.
        sources = list(packages)
        contract_roots = sorted({package.split("/tests", 1)[0] for package in packages
                                 if "/tests/" in package or package.endswith("/tests")})
        if contract_roots:
            sources += checked_output(["go", "list", *(root + "/..." for root in contract_roots)],
                                      ROOT, processes).splitlines()
        covered = [package for package in dict.fromkeys(sources)
                   if not {"tests", "testkit", "testdb"}.intersection(package.split("/"))]
        flags += ["-cover", "-covermode=atomic", "-coverpkg=" + ",".join(covered)]
    # Registry has process-wide allocation/throughput guards. The throughput
    # guard already excludes race builds; retain ordinary execution otherwise.
    sharded = ([REGISTRY] if args.race else []) + list(API_SHARDS)
    other = [package for package in packages if package not in sharded]
    profiles, results, preparation = [], [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        futures = []
        try:
            if other:
                command = ["go", "test", "-json", "-count=1", "-timeout=10m", *flags]
                if args.coverprofile:
                    profiles.append(output / "packages.cover")
                    command.append(f"-coverprofile={profiles[-1]}")
                futures.append(executor.submit(run_task, "packages", [*command, *other], ROOT,
                                               output, None, processes, other))
            for package in sharded:
                if package not in packages:
                    continue
                relative = package.removeprefix(COORDINATOR + "/")
                name = relative.replace("/", "-")
                cwd = ROOT / "coordinator" / relative
                binary = output / f"{name}.test"
                started = time.monotonic()
                checked_output(["go", "test", "-c", *flags, "-o", str(binary), package], ROOT, processes)
                listing_env = os.environ.copy()
                if args.coverprofile:
                    # Initializers run during listing, but it is not test coverage.
                    listing_coverage = output / f"{name}-listing-coverage"
                    listing_coverage.mkdir()
                    listing_env["GOCOVERDIR"] = str(listing_coverage)
                listing = checked_output([str(binary), "-test.list=."], cwd, processes, listing_env)
                names = test_names(listing)
                shards = partition(names, 2 * args.jobs if args.jobs > 1 else 1)
                preparation.append({"package": package, "seconds": round(time.monotonic() - started, 3)})
                (output / f"{name}-tests.json").write_text(json.dumps(shards, indent=2) + "\n")
                print(f"Discovered {len(names)} {name} tests; {len(shards)} isolated shards, {args.jobs} workers", flush=True)
                for i, shard in enumerate(shards):
                    label = f"{name}-{i + 1}"
                    command = ["go", "tool", "test2json", "-t", "-p", package, str(binary),
                               "-test.v=test2json", "-test.paniconexit0", "-test.count=1", "-test.timeout=10m",
                               "-test.run=^(" + "|".join(re.escape(test) for test in shard) + ")$"]
                    if args.coverprofile:
                        profiles.append(output / f"{label}.cover")
                        command.append(f"-test.coverprofile={profiles[-1]}")
                    futures.append(executor.submit(run_task, label, command, cwd, output, shard, processes, [package]))
            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                results.append(result)
                status = "ok" if result["passed"] else "FAIL"
                print(f"{status}\t{result['task']}\t{result['seconds']:.3f}s", flush=True)
                if not result["passed"]:
                    print(result["error"], flush=True)
                    print((output / f"{result['task']}.jsonl").read_text(), flush=True)
                    print((output / f"{result['task']}.stderr").read_text(), flush=True)
        except BaseException:
            processes.cancel()
            raise
        finally:
            (output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
            (output / "preparation.json").write_text(json.dumps(preparation, indent=2) + "\n")
    if not all(result["passed"] for result in results):
        return 1
    if args.coverprofile:
        merge_coverage(profiles, Path(args.coverprofile).resolve())
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--race", action="store_true")
    parser.add_argument("--coverprofile", type=str)
    parser.add_argument("--jobs", type=positive, default=4)
    parser.add_argument("--output-dir", type=Path, help="retain JSON test events, membership, logs and profiles")
    parser.add_argument("packages", nargs="*", default=["./coordinator/..."])
    args = parser.parse_args()
    processes = Processes()

    def interrupted(signum, _frame):
        processes.interrupted = True
        processes.cancel()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    started = time.monotonic()
    try:
        # Even retained runs get a unique directory: concurrent runs never share
        # a binary, event stream or coverage counter file.
        if args.output_dir:
            args.output_dir.mkdir(parents=True, exist_ok=True)
            output = Path(tempfile.mkdtemp(prefix="run-", dir=args.output_dir.resolve()))
            print(f"Test artifacts: {output}", flush=True)
            code = run(args, output, processes)
        else:
            with tempfile.TemporaryDirectory(prefix="coordinator-tests-") as directory:
                code = run(args, Path(directory), processes)
        print(f"Coordinator tests: {time.monotonic() - started:.3f}s total", flush=True)
        return 130 if processes.interrupted else code
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Coordinator tests failed: {error}", flush=True)
        return 130 if processes.interrupted else 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
