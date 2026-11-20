"""CPU-only, bounded descriptor-cache/alignment observation; never runs MLX."""
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import re
import subprocess
import time
from pathlib import Path


def observe():
    raw = subprocess.run(['/usr/bin/vm_stat'], capture_output=True, text=True,
                         check=True, timeout=3).stdout
    page = int(re.search(r'page size of (\d+) bytes', raw).group(1))
    values = {key: int(re.search(re.escape(key) + r':\s*(\d+)', raw).group(1)) * page
              for key in ['Pages free', 'Anonymous pages', 'File-backed pages']}
    assert values['Pages free'] >= 6 * 1024**3, 'actual free-memory floor'
    return dict(monotonic=time.monotonic(), values=values, rawVMStat=raw)


libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
libc.posix_memalign.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_size_t,
                              ctypes.c_size_t]
libc.posix_memalign.restype = ctypes.c_int
libc.free.argtypes = [ctypes.c_void_p]
libc.free.restype = None
libc.pread.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int64]
libc.pread.restype = ctypes.c_ssize_t
alignment = 16384
chunk = 8 * 1024**2
length = 512 * 1024**2
allocated = ctypes.c_void_p()
assert libc.posix_memalign(ctypes.byref(allocated), alignment, chunk + alignment) == 0
assert allocated.value % alignment == 0
path = max(Path('/Users/developer/DarkbloomDev/models/Qwen3.5-9B').glob('*.safetensors'),
           key=lambda item: item.stat().st_size)
results = []
try:
    for passno, (name, buffer_shift, file_shift) in enumerate([
            ('aligned_buffer_aligned_offset', 0, 0),
            ('unaligned_buffer_aligned_offset', 32, 0),
            ('aligned_buffer_unaligned_offset', 0, 8)]):
        fd = os.open(path, os.O_RDONLY)
        base_offset = passno * length + file_shift
        assert base_offset + length <= os.fstat(fd).st_size
        start = time.monotonic()
        count = 0
        digest = hashlib.sha256()
        samples = [observe()]
        try:
            assert fcntl.fcntl(fd, 48, 1) == 0  # F_NOCACHE
            assert fcntl.fcntl(fd, 45, 0) == 0  # F_RDAHEAD
            destination = allocated.value + buffer_shift
            while count < length:
                request = min(chunk, length - count)
                got = libc.pread(fd, destination, request, base_offset + count)
                if got < 0 and ctypes.get_errno() == errno.EINTR:
                    assert time.monotonic() - start < 30
                    continue
                assert got == request, (got, request, ctypes.get_errno())
                digest.update(memoryview((ctypes.c_ubyte * got).from_address(destination)).cast('B'))
                count += got
                if count % (64 * 1024**2) == 0:
                    samples.append(observe())
                assert time.monotonic() - start < 30
        finally:
            os.close(fd)
        samples.append(observe())
        result = dict(kind='aligned_checkpoint_cpu_read_pass', name=name,
                      noCache=True, readAhead=False, file=path.name,
                      fileSize=path.stat().st_size, alignment=alignment,
                      bufferModuloAlignment=destination % alignment,
                      fileOffset=base_offset, fileOffsetModuloAlignment=base_offset % alignment,
                      bufferBytes=chunk + alignment, bytes=count,
                      seconds=time.monotonic() - start, sha256=digest.hexdigest(), samples=samples)
        results.append(result)
        print(json.dumps(result), flush=True)
finally:
    libc.free(allocated)
print(json.dumps(dict(kind='aligned_checkpoint_cpu_read_completed', modelInference=False,
                      passes=len(results))), flush=True)
