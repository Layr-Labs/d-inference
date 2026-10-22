"""Bounded observation of actual local processes; no pre-existing process is signalled."""
import hashlib
import os
from pathlib import PurePath
import selectors
import subprocess
import time
from binding_common import require

COMMAND = ['/bin/ps', '-Aww', '-o', 'pid=,uid=,comm=']
OUTPUT_LIMIT = 1024 * 1024
NATIVE_OR_OWNER_NAMES = frozenset({'cluster-inference', 'owner-controller', 'targetverificationcheck', 'targetverificationsessioncheck',
    'collectiveallocationcheck', 'mtptinyforwardcheck', 'mtpselectedloadcheck', 'windowedrequeststatecheck'})


def parse_processes(raw):
    text = raw.decode('utf-8', errors='strict')
    require(text and text.endswith('\n'), 'Incomplete process observation')
    rows = []
    for line in text.splitlines():
        parts = line.strip().split(maxsplit=2)
        require(len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit()
                and int(parts[0]) >= 0 and parts[2], 'Malformed process observation')
        name = PurePath(parts[2]).name.lower()
        # Conservative installed and private owner/native/reference executable families.
        if name.startswith(('darkbloom', 'qwen')) or name in NATIVE_OR_OWNER_NAMES:
            rows.append(dict(pid=int(parts[0]), uid=int(parts[1]), executable=parts[2]))
    return dict(processCount=len(text.splitlines()), prohibited=rows,
                stdoutSHA256=hashlib.sha256(raw).hexdigest())


def observe(until):
    start = time.monotonic_ns()
    deadline = min(until, time.monotonic() + 3.0)
    require(deadline > time.monotonic(), 'No time remains for process observation')
    child = subprocess.Popen(COMMAND, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, close_fds=True, env={'PATH':'/usr/bin:/bin', 'LC_ALL':'C'})
    selector = selectors.DefaultSelector()
    output = [bytearray(), bytearray()]
    try:
        for index, stream in enumerate((child.stdout, child.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, index)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            require(remaining > 0, 'Process observation deadline expired')
            for key, _ in selector.select(remaining):
                data = os.read(key.fileobj.fileno(), 16384)
                if not data:
                    selector.unregister(key.fileobj)
                else:
                    output[key.data].extend(data)
                    require(sum(map(len, output)) <= OUTPUT_LIMIT, 'Process observation exceeds output bound')
        child.wait(timeout=max(0.001, deadline - time.monotonic()))
        require(child.returncode == 0 and not output[1], 'Process observation failed')
        result = parse_processes(bytes(output[0]))
        result.update(command=COMMAND, observedStartMonotonicNS=start,
                      observedEndMonotonicNS=time.monotonic_ns(), observerPID=child.pid)
        return result
    finally:
        selector.close()
        child.stdout.close(); child.stderr.close()
        # This is solely our newly launched read-only observer, never an owner,
        # native worker, provider, process group or caller-supplied PID.
        if child.poll() is None:
            child.kill()
        child.wait(timeout=1)
