"""The four fixed JACCL TCP bootstrap retry diagnostics; no general log filter."""
import hashlib
import select

from stage_checks.common import require
from worker_processes import PipeWorkers


RETRY_LINES = tuple(('[jaccl] Connection attempt %d waiting %d ms\n' % (i, 1000 << i)).encode('ascii')
                    for i in range(4))
MAX_RETRY_BYTES = sum(map(len, RETRY_LINES))


class RetryDiagnostics:
    def __init__(self, rank):
        require(type(rank) is int and rank in (0, 1), 'Invalid retry diagnostic rank')
        self.rank = rank
        self.raw = bytearray()
        self.pending = bytearray()
        self.count = 0
        self.sealed = False

    def feed(self, raw):
        require(type(raw) is bytes and raw, 'Invalid retry diagnostic bytes')
        require(self.rank == 1 and not self.sealed, 'Unexpected worker stderr outside rank1 bootstrap')
        require(len(self.raw) + len(raw) <= MAX_RETRY_BYTES, 'JACCL retry diagnostic byte cap')
        self.raw.extend(raw)
        for byte in raw:
            require(self.count < len(RETRY_LINES), 'Too many JACCL retries')
            self.pending.append(byte)
            expected = RETRY_LINES[self.count]
            require(expected.startswith(self.pending), 'Unexpected worker stderr')
            if self.pending == expected:
                self.count += 1
                self.pending.clear()

    def end(self):
        require(not self.pending, 'Incomplete JACCL retry diagnostic')

    def seal(self):
        self.end()
        self.sealed = True

    def summary(self):
        return dict(schema='jaccl_bootstrap_retry_diagnostics_v1', rank=self.rank,
                    lineCount=self.count, bytes=len(self.raw), sha256=hashlib.sha256(self.raw).hexdigest(),
                    bootstrapSealed=self.sealed, partialLine=bool(self.pending), physicalTransferQualified=False)


def validate_retry_bytes(rank, raw):
    policy = RetryDiagnostics(rank)
    if raw:
        policy.feed(raw)
    policy.seal()
    return policy.summary()


class JacclPipeWorkers(PipeWorkers):
    """Remote one-child specialization; inherited process ownership is unchanged."""
    def __init__(self, *args, jaccl_rank, **kwargs):
        self.retry_diagnostics = RetryDiagnostics(jaccl_rank)
        super().__init__(*args, **kwargs)
        require(len(self.specs) == 1, 'One remote native child required')

    def _read(self, index, stream, handle):
        if stream != 'stderr':
            return super()._read(index, stream, handle)
        # os.read and exact byte retention match the inherited stderr branch.
        import os
        raw = os.read(handle.fileno(), 65536)
        if not raw:
            self.selector.unregister(handle)
            self.eof.add((index, stream))
            self.retry_diagnostics.end()
            return
        self._retain(index, stream, raw)
        self.retry_diagnostics.feed(raw)

    def seal_bootstrap(self):
        # Native emits these diagnostics before ready. Drain already-written
        # stderr independently of selector ordering before closing the allowance.
        handle = self.children[0].stderr
        while (0, 'stderr') not in self.eof and select.select([handle], [], [], 0)[0]:
            self._read(0, 'stderr', handle)
        self.retry_diagnostics.seal()
