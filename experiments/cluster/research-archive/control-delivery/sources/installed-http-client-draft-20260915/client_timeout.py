"""Unchanged absolute timer extracted from the repository streaming client."""
from contextlib import contextmanager
import signal


@contextmanager
def absolute_timeout(seconds):
    """Bound DNS, connect, headers and streaming together, including trickles."""
    if signal.getitimer(signal.ITIMER_REAL) != (0.0, 0.0):
        raise RuntimeError("Existing process alarm; use a standalone client")
    previous = signal.getsignal(signal.SIGALRM)
    def expired(signum, frame):
        raise TimeoutError("Absolute request timeout")
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)

