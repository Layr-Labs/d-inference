#!/usr/bin/env python3
"""One-shot administrative recovery of the two pinned MTP physical-1 journals."""
import argparse
import json
import os
from pathlib import Path
import signal
import sys
import time
from recovery_contract import (CANONICAL_DIRECTORY, CLUSTER, EPOCH, CONTROLLER_SHA, EXECUTION_SHA,
                               evidence, known_journal, digest)
from recovery_files import HeldJournal, DurableBackup, RecoveryRefusal, require, contents
from recovery_processes import observe


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode()


def recover(directory, journal, raw_evidence, until, process_observer=observe):
    """Only the CLI's fixed canonical directory is exposed; alternate path/observer are CPU test seams."""
    expected = raw_evidence['rank%d-journal.json' % journal['rank']]
    known_journal(journal['rank'], expected)
    held = None
    backup = None
    result = dict(schema='known_mtp_administrative_recovery_v1', administrativeRecovery=True,
        failedRunRemainsFailed=True, protocolReleaseAcknowledged=False, cleared=False,
        truncateAttempted=False, emptyReadback=False, rank=journal['rank'], peerID=journal['peerID'],
        journal=journal, journalSHA256=digest(expected), controllerSHA256=CONTROLLER_SHA,
        failedExecutionSHA256=EXECUTION_SHA, startedMonotonicNS=time.monotonic_ns(), observations=[])
    try:
        require(time.monotonic() < until, 'Administrative operation deadline expired')
        held = HeldJournal(directory)
        held.require_bytes(expected)
        result['canonicalFileIdentity'] = held.file_id
        result['canonicalDirectoryIdentity'] = held.directory_id
        result['observations'].append(process_observer(until))
        require(not result['observations'][-1]['prohibited'], 'Live owner/native process observed')
        held.require_bytes(expected)
        backup = DurableBackup(held, journal['leaseID'])
        result['backupDirectory'] = str(Path(directory) / backup.name)
        backup.add('journal.before.json', expected)
        for name, raw in raw_evidence.items():
            backup.add('evidence-' + name, raw)
        backup.add('authorization-before-clear.json', encoded(result))
        backup.verify()
        # Sample again after durable backup while still holding the canonical
        # flock; cooperating owners/solo callers cannot acquire the device.
        result['observations'].append(process_observer(until))
        require(not result['observations'][-1]['prohibited'], 'Live owner/native process observed')
        backup.add('observations-before-clear.json', encoded(result['observations']))
        backup.verify()
        held.require_bytes(expected)
        require(time.monotonic() < until, 'Administrative operation deadline expired before clear')
        result['truncateAttempted'] = True
        os.ftruncate(held.fd, 0)
        os.fsync(held.fd)
        os.fsync(held.directory)
        held.same_path()
        require(contents(held.fd, 16384) == b'', 'Canonical empty readback failed')
        result.update(cleared=True, emptyReadback=True, emptySHA256=digest(b''),
                      completedMonotonicNS=time.monotonic_ns())
        backup.add('administrative-result.json', encoded(result))
        backup.verify()
        return result
    except BaseException as error:
        result['error'] = (type(error).__name__ + ': ' + str(error))[:2048]
        result['completedMonotonicNS'] = time.monotonic_ns()
        if backup is not None:
            try:
                backup.add('administrative-failure.json', encoded(result))
            except BaseException as receipt_error:
                result['failureReceiptError'] = type(receipt_error).__name__
        return result
    finally:
        if backup is not None: backup.close()
        if held is not None: held.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--rank', type=int, choices=[0, 1], required=True)
    for name in ('peer', 'cluster-id', 'epoch', 'journal-sha256', 'controller-sha256'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--confirm-administrative-recovery', action='store_true', required=True)
    args = parser.parse_args()
    def interrupted(number, _frame):
        raise RecoveryRefusal('Administrative recovery interrupted: ' + str(number))
    for number in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, interrupted)
    signal.alarm(30)
    try:
        require(sys.platform == 'darwin', 'This maintenance command is only for the two Darwin hosts')
        require(args.cluster_id == CLUSTER and args.epoch == EPOCH, 'Explicit cluster/epoch binding differs')
        journal, raw = evidence(Path(__file__).resolve().parent / 'evidence', args.rank, args.peer,
                                args.journal_sha256, args.controller_sha256)
        result = recover(CANONICAL_DIRECTORY, journal, raw, time.monotonic() + 20)
    except BaseException as error:
        result = dict(schema='known_mtp_administrative_recovery_v1', administrativeRecovery=True,
            failedRunRemainsFailed=True, protocolReleaseAcknowledged=False, cleared=False,
            error=(type(error).__name__ + ': ' + str(error))[:2048])
    sys.stdout.buffer.write(encoded(result)); sys.stdout.buffer.flush()
    signal.alarm(0)
    return 0 if result['cleared'] and 'error' not in result else 1


if __name__ == '__main__':
    raise SystemExit(main())
