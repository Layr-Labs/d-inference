"""Exercise the Bash monitor with owned log, process and sampling stubs."""

import csv
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = Path(__file__).with_name("cache_soak_monitor.sh")


class MonitorTests(unittest.TestCase):
    def fixture(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        commands = root / "commands"
        commands.mkdir()
        common = f"#!{sys.executable}\n" + '''import os, signal, time
from pathlib import Path
root = Path(os.environ["SOAK_MONITOR_FIXTURE"])
def await_file(path):
    deadline = time.monotonic() + 10
    while not path.exists():
        if time.monotonic() > deadline:
            raise SystemExit("fixture rendezvous timed out: " + str(path))
        time.sleep(0.005)
'''
        stubs = {
            "log": common + '''signal.signal(signal.SIGTERM, lambda *_: exit(0))
(root / "log-ready").touch()
index = 0
while True:
    path = root / ("chunk-" + str(index))
    await_file(path)
    os.write(1, path.read_bytes())
    (root / ("written-" + str(index))).touch()
    index += 1
''',
            "sleep": common + '''path = root / "tick-count"
index = int(path.read_text()) if path.exists() else 0
path.write_text(str(index + 1))
(root / ("tick-" + str(index))).touch()
await_file(root / ("advance-" + str(index)))
''',
            "pgrep": "#!/bin/sh\nexit 1\n",
            "pmset": "#!/bin/sh\nprintf 'CPU_Speed_Limit = 100\\n'\n",
        }
        for name, source in stubs.items():
            path = commands / name
            path.write_text(source)
            path.chmod(0o755)
        log = (root / "monitor-output").open("w")
        self.addCleanup(log.close)
        process = subprocess.Popen(
            ["/bin/bash", str(SCRIPT), "--kv-dir", str(root / "absent-cache"),
             "--proc", "fixture-only", "--interval", "1", "--out-csv", str(root / "samples.csv"),
             "--events-log", str(root / "events.log"), "--raw-log", str(root / "raw.log")],
            env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                 "SOAK_MONITOR_FIXTURE": str(root)},
            stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
        )

        def cleanup():
            if process.poll() is None:
                # The fixture exclusively owns the new session and its stubs.
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)

        self.addCleanup(cleanup)
        self.wait_file(root / "log-ready")
        self.wait_file(root / "tick-0")
        return root, process

    def wait_file(self, path):
        deadline = time.monotonic() + 5
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.005)
        self.assertTrue(path.exists(), f"fixture did not reach {path.name}")

    def append(self, root, index, chunk):
        (root / f"chunk-{index}").write_bytes(chunk)
        self.wait_file(root / f"written-{index}")

    def tick(self, root, index):
        (root / f"advance-{index}").touch()
        self.wait_file(root / f"tick-{index + 1}")

    def stop(self, root, process, tick, signum=signal.SIGTERM):
        process.send_signal(signum)
        # Bash delivers the trap after its owned foreground sampler returns.
        (root / f"advance-{tick}").touch()
        try:
            result = process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.fail("monitor resumed sampling after its stop signal")
        self.assertEqual(result, 128 + signum)
        self.assertEqual((root / "events.log").read_text().count("monitor: stopping"), 1)

    def rows(self, root):
        with (root / "samples.csv").open() as source:
            return list(csv.DictReader(source))

    def test_stop_signals_end_sampling_and_cleanup_once(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signum=signum):
                root, process = self.fixture()
                self.stop(root, process, 0, signum)
                self.assertEqual(len(self.rows(root)), 1)

    def test_partial_log_line_is_counted_once_when_completed(self):
        root, process = self.fixture()
        self.append(root, 0, b"prefix read ")
        self.tick(root, 0)
        self.assertEqual(self.rows(root)[-1]["decrypt_fail"], "0")
        self.append(root, 1, b"failed: owned fixture\n")
        self.tick(root, 1)
        self.assertEqual(self.rows(root)[-1]["decrypt_fail"], "1")
        self.tick(root, 2)
        self.assertEqual(self.rows(root)[-1]["decrypt_fail"], "0")
        self.assertEqual(sum(int(row["decrypt_fail"]) for row in self.rows(root)), 1)
        self.assertIn("prefix read failed: owned fixture", (root / "events.log").read_text())
        self.stop(root, process, 3)

    def test_complete_lines_and_partial_suffix_preserve_marker_windows(self):
        root, process = self.fixture()
        self.append(root, 0, b"encrypted prefix cache active\nwrote 3 chunks to x\n"
                    b"wrote 2 chunks to y\nprefix cache stats: hitRate=83.5%\nprefix cache dis")
        self.tick(root, 0)
        first = self.rows(root)[-1]
        self.assertEqual((first["active"], first["store"], first["hit_rate"], first["disabled"]),
                         ("1", "2", "83.5", "0"))
        self.append(root, 1, b"abled\n")
        self.tick(root, 1)
        second = self.rows(root)[-1]
        self.assertEqual((second["active"], second["store"], second["hit_rate"], second["disabled"]),
                         ("0", "0", "83.5", "1"))
        self.stop(root, process, 2)


if __name__ == "__main__":
    unittest.main()
