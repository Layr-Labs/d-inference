"""Disposable PostgreSQL fixture; never connect to an existing server."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile


TOOLS = ("initdb", "pg_ctl", "psql", "postgres")


def _binaries_in(directory):
    paths = {name: directory / name for name in TOOLS}
    if all(path.is_file() and os.access(path, os.X_OK) for path in paths.values()):
        return {name: str(path) for name, path in paths.items()}
    return None


def discover_postgres_binaries(version_root=Path("/usr/lib/postgresql")):
    """Find a complete installation, including Debian's off-PATH server tools."""
    for name in TOOLS:
        executable = shutil.which(name)
        if executable:
            found = _binaries_in(Path(executable).resolve().parent)
            if found:
                return found
    pg_config = shutil.which("pg_config")
    if pg_config:
        try:
            result = subprocess.run([pg_config, "--bindir"], check=True,
                                    capture_output=True, text=True, timeout=5)
            found = _binaries_in(Path(result.stdout.strip()))
            if found:
                return found
        except (OSError, subprocess.SubprocessError):
            # Unavailable or broken pg_config falls through to versioned-directory discovery.
            pass
    versions = [path for path in version_root.glob("*/bin")
                if all(part.isdigit() for part in path.parent.name.split("."))]
    versions.sort(key=lambda path: tuple(map(int, path.parent.name.split("."))), reverse=True)
    for directory in versions:
        found = _binaries_in(directory)
        if found:
            return found
    return None


class LocalPostgres:
    def __init__(self, binaries):
        self.binaries = binaries
        # macOS PostgreSQL must not initialize a locale that starts background
        # threads before the postmaster forks. Do not mutate the caller's env.
        self.environment = dict(os.environ, LC_ALL="C")
        self.temp = tempfile.TemporaryDirectory(prefix="fc-monitor-", dir="/tmp")
        self.directory = Path(self.temp.name)
        self.data = self.directory / "data"
        self.log = self.directory / "server.log"
        with socket.socket() as allocator:
            allocator.bind(("127.0.0.1", 0))
            self.port = str(allocator.getsockname()[1])
        # The server never listens on TCP. Its private socket directory also
        # isolates concurrently running fixtures if their allocated ports repeat.
        self.client = [binaries["psql"], "-X", "-qAt", "-v", "ON_ERROR_STOP=1",
                       "-h", str(self.directory), "-p", self.port,
                       "-U", "postgres", "-d", "postgres"]

    def _run(self, command, **kwargs):
        return subprocess.run(command, check=True, capture_output=True, text=True,
                              env=self.environment, **kwargs)

    def start(self):
        try:
            self._run([self.binaries["initdb"], "-D", str(self.data), "-A", "trust",
                       "-U", "postgres", "--no-locale", "--encoding=UTF8"])
            self._run([self.binaries["pg_ctl"], "-D", str(self.data), "-l", str(self.log),
                       "-o", f"-F -h '' -k {self.directory} -p {self.port}", "-w", "start"])
        except subprocess.CalledProcessError as error:
            log = self.log.read_text(errors="replace") if self.log.exists() else ""
            raise RuntimeError(f"Disposable PostgreSQL startup failed:\n"
                               f"{error.stdout or ''}{error.stderr or ''}{log}") from error

    def close(self):
        if self.temp is None:
            return
        # pg_ctl can fail after starting the child: clean up that case too.
        if (self.data / "postmaster.pid").exists():
            self._run([self.binaries["pg_ctl"], "-D", str(self.data), "-m", "immediate", "-w", "stop"])
        self.temp.cleanup()
        self.temp = None

    def execute(self, sql, *args):
        return self._run(self.client + list(args), input=sql).stdout
