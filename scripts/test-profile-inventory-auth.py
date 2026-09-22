#!/usr/bin/env python3
"""Exercise profile-inventory authentication in a PTY using fake input only."""
import errno
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "provider-swift/Sources/ProviderCore/Security/ProfileInventoryAuthorization.swift"


@unittest.skipUnless(sys.platform == "darwin", "macOS process-group regression")
class ProfileInventoryAuthorizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("swiftc"):
            raise RuntimeError("swiftc is required for the macOS regression")
        cls.temporary = tempfile.TemporaryDirectory(prefix="profile-auth-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        root = Path(cls.temporary.name)
        main = root / "main.swift"
        main.write_text('''import Foundation
let args = CommandLine.arguments
let output: Data?
if args[1] == "noninteractive" {
    output = ProfileInventoryAuthorization.readAuthenticatedProfiles(arguments: [])
} else {
    output = ProfileInventoryAuthorization.runInCurrentProcessGroup(
        executable: args[1], arguments: Array(args.dropFirst(2)))
}
if let output { print(String(decoding: output, as: UTF8.self), terminator: "") }
print("AUTHORIZATION_SUCCESS=\\(output != nil)")
''')
        cls.binary = root / "probe"
        subprocess.run(["swiftc", "-swift-version", "6", str(SOURCE), str(main), "-o", str(cls.binary)], check=True)
        cls.fake_prompt = root / "fake_prompt.py"
        cls.fake_prompt.write_text('''import os, termios
fd = os.open("/dev/tty", os.O_RDWR)
assert os.getpgrp() == os.tcgetpgrp(fd), "authentication lost foreground terminal ownership"
original = termios.tcgetattr(fd)
hidden = list(original)
hidden[3] &= ~termios.ECHO
try:
    termios.tcsetattr(fd, termios.TCSANOW, hidden)
    os.write(fd, b"FAKE_AUTH_PROMPT> ")
    value = os.read(fd, 128)
    assert value == b"DUMMY_TEST_INPUT\\n"
finally:
    termios.tcsetattr(fd, termios.TCSANOW, original)
    os.close(fd)
print("FAKE_AUTH_COMPLETED", flush=True)
''')

    def test_prompt_reads_input_without_echo_or_job_control_stop(self):
        pid, terminal = pty.fork()
        if pid == 0:
            os.execl(str(self.binary), str(self.binary), sys.executable, str(self.fake_prompt))
        output = b""
        sent = False
        finished = False
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if select.select([terminal], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(terminal, 8192)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output += chunk
                    self.assertLess(len(output), 65536)
                    if b"FAKE_AUTH_PROMPT>" in output and not sent:
                        self.assertFalse(termios.tcgetattr(terminal)[3] & termios.ECHO)
                        os.write(terminal, b"DUMMY_TEST_INPUT\n")
                        sent = True
                child, status = os.waitpid(pid, os.WNOHANG)
                if child:
                    finished = True
                    self.assertTrue(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0)
                    # Drain any final lines written just before the process exited.
                    while select.select([terminal], [], [], 0)[0]:
                        try:
                            chunk = os.read(terminal, 8192)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                break
                            raise
                        if not chunk:
                            break
                        output += chunk
                    break
            self.assertTrue(sent, output.decode(errors="replace"))
            self.assertIn(b"FAKE_AUTH_COMPLETED", output)
            self.assertIn(b"AUTHORIZATION_SUCCESS=true", output)
            self.assertNotIn(b"DUMMY_TEST_INPUT", output)
            self.assertTrue(termios.tcgetattr(terminal)[3] & termios.ECHO)
        finally:
            if not finished:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except OSError:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except OSError:
                        pass
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass
            os.close(terminal)

    def test_nonzero_exit_and_failed_spawn_deny_authorization(self):
        for args in (["/usr/bin/false"], ["/nonexistent/profile-auth-test"]):
            result = subprocess.run([str(self.binary), *args], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.stdout.strip(), "AUTHORIZATION_SUCCESS=false")

    def test_noninteractive_input_never_launches_sudo(self):
        result = subprocess.run([str(self.binary), "noninteractive"], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.stdout.strip(), "AUTHORIZATION_SUCCESS=false")
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
