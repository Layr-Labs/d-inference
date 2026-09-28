"""One agreed token stream and bounded callback dispatch within an epoch."""

import threading

from . import persistent_protocol as protocol
from .persistent_io import PersistentCohortError


def call_callback(callback, step, token, deadline, io, check_live):
    done, failure = threading.Event(), []
    def run():
        try:
            # Check on the callback thread itself: cancellation before that
            # thread runs must not dispatch new user code for a retired epoch.
            check_live()
            callback(step, token)
        except BaseException as error:
            failure.append(error)
        finally:
            done.set()
    threading.Thread(target=run, daemon=True, name='persistent-token-callback').start()
    while not done.is_set():
        io.pump(deadline)
    io._remaining(deadline)
    if failure:
        raise PersistentCohortError(f'Token callback failed: {failure[0]}') from failure[0]


def run_request(io, command, ready_records, deadline, callback, check_live):
    io.send(command, deadline)
    for rank, ready in enumerate(ready_records):
        protocol.frame(io.receive(rank, deadline), 'accepted', command['epoch'], rank,
                       command['sequence'], command, ready['modelLoadID'])
    tokens = []
    for step in range(command['outputTokens']):
        agreed = None
        for rank in range(len(ready_records)):
            record = protocol.frame(io.receive(rank, deadline), 'token', command['epoch'], rank,
                                    command['sequence'], command)
            protocol.same(record['step'], step, 'token step')
            token = record['token']
            protocol.need(type(token) is int and 0 <= token < ready_records[0]['identity']['vocabularySize'],
                          'Worker emitted an invalid token')
            if agreed is None:
                agreed = token
            protocol.same(token, agreed, 'rank token agreement')
        tokens.append(agreed)
        if callback is not None:
            call_callback(callback, step, agreed, deadline, io, check_live)
    return [protocol.completed(io.receive(rank, deadline), command, ready, rank, tokens)
            for rank, ready in enumerate(ready_records)]
