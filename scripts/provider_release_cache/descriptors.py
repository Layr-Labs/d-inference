"""Explicit ownership for descriptors used by anchored filesystem operations."""

from contextlib import contextmanager, ExitStack
import os
import sys


@contextmanager
def open_descriptor(path, flags, mode=0o777, *, dir_fd=None):
    descriptor = os.open(path, flags, mode, dir_fd=dir_fd)
    try:
        yield descriptor
    finally:
        os.close(descriptor)


def own_descriptor(stack: ExitStack, path, flags, mode=0o777, *, dir_fd=None):
    """Register ownership without leaking if the stack cannot track a scope."""
    scope = open_descriptor(path, flags, mode, dir_fd=dir_fd)
    descriptor = scope.__enter__()
    try:
        stack.push(scope)
    except BaseException:
        # enter_context cannot unwind a resource whose registration failed.
        scope.__exit__(*sys.exc_info())
        raise
    return descriptor
