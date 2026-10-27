"""Only the pinned rank1 TCPAllGather retry progress; never success evidence."""
from binding_common import require

LINES = tuple(('[jaccl] Connection attempt %d waiting %d ms\n' %
               (attempt, 1000 << attempt)).encode('ascii') for attempt in range(4))
MAX_BYTES = sum(map(len, LINES))


class JacclStartupProgress:
    def __init__(self):
        self.completed = 0
        self.partial = bytearray()
        self.closed = False

    def feed(self, raw):
        require(not self.closed and type(raw) is bytes and raw, 'Invalid stderr parser state/input')
        for byte in raw:
            require(self.completed < len(LINES), 'Extra JACCL stderr after bounded retries')
            expected = LINES[self.completed]
            require(byte == expected[len(self.partial)], 'Unknown, skipped or reordered JACCL stderr')
            self.partial.append(byte)
            if len(self.partial) == len(expected):
                self.completed += 1
                self.partial.clear()

    def finish(self):
        require(not self.closed and not self.partial, 'Partial/repeated JACCL stderr EOF')
        self.closed = True

    def summary(self):
        require(self.closed and not self.partial, 'JACCL stderr drain incomplete')
        return dict(policy='exact_ordered_jaccl_tcp_retry_v1', completedLines=self.completed,
                    bytes=sum(len(x) for x in LINES[:self.completed]), completeEOF=True,
                    connectionSuccessEstablished=False)


def validate_retained(raw, mode):
    require(type(raw) is bytes and mode in ('full', 'stage0', 'stage1'), 'Wrong retained stderr role')
    if mode != 'stage1':
        require(raw == b'', 'Unexpected strict-role native stderr')
        return dict(policy='empty_stderr_v1', completedLines=0, bytes=0,
                    completeEOF=True, connectionSuccessEstablished=False)
    require(len(raw) <= MAX_BYTES, 'JACCL stderr exceeds four-line byte bound')
    parser = JacclStartupProgress()
    if raw:
        parser.feed(raw)
    parser.finish()
    return parser.summary()
