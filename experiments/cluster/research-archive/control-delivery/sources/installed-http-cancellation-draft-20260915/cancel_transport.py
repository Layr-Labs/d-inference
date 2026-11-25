"""One planned shutdown of an already submitted HTTP request's actual socket."""

import socket
import threading
import time


class PlannedDisconnect:
    def __init__(self, transport, origin_ns):
        if transport is None:
            raise ValueError("No submitted request transport")
        # Keep the socket object, including when HTTPConnection detaches it for
        # Connection: close. Never store/reuse an integer descriptor.
        self.transport = transport
        self.origin_ns = origin_ns
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread = None
        self.trigger_ns = None
        self.shutdown_error = None

    def arm(self, seconds):
        if self.thread is not None:
            raise RuntimeError("Disconnect timer already armed")
        def wait():
            if not self.stop_event.wait(seconds):
                self.fire()
        self.thread = threading.Thread(target=wait, name="http-planned-disconnect", daemon=True)
        self.thread.start()

    def fire(self):
        with self.lock:
            if self.stop_event.is_set() or self.trigger_ns is not None:
                return
            self.trigger_ns = time.monotonic_ns() - self.origin_ns
            try:
                # shutdown interrupts blocked getresponse/readline, including
                # a partial line. Closing a buffered response on this timer
                # thread could instead wait on its reader lock.
                self.transport.shutdown(socket.SHUT_RDWR)
            except OSError as error:
                self.shutdown_error = type(error).__name__

    def stop(self):
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=1)
            if self.thread.is_alive():
                raise RuntimeError("Disconnect timer did not join")

