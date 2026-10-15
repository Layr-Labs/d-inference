"""Reuse the reference producer with a retained same-PID canonical lock."""
from pathlib import Path
import os
import time
from binding_common import canonical, parse, require, same
from binding_inputs import snapshot
from reference_inputs import native_spec, write_json
from reference_settings import REMOTE, require_short
from mtp_journal import device_directory, observe as journal, require_empty
from target_processes import observe as processes
from worker_contract import WorkerSpec, workers


def prepare(job, run):
    require_short(job)
    same(Path(run), REMOTE / 'runs/reference-1', 'Fresh reference namespace')
    initial = journal(device_directory()); require_empty(initial)
    write_json(run / 'journal-before.json', initial)
    live = processes(time.monotonic() + 4)
    require(not live['prohibited'], 'A native/owner is already live')
    write_json(run / 'processes-before.json', live)
    spec = native_spec(job)
    binary = Path(spec.argv[0])
    verified = snapshot(binary, 256*1024**2, keep=False)
    same(verified['sha256'], job['native_sha256'], 'Exact native bytes immediately before gate preparation')
    launch = dict(binary=str(binary), binaryIdentity=list(verified['identity']),
                  job=str(run / 'job.json'), jobSHA256=snapshot(run / 'job.json', 16384)['sha256'])
    write_json(run / 'launch.json', launch)
    digest = snapshot(run / 'launch.json', 16384)['sha256']
    return workers([WorkerSpec(('/usr/bin/python3', '-B', str(REMOTE / 'package/reference_gate.py'),
                               '--launch', str(run / 'launch.json'), '--launch-sha256', digest),
                              spec.env, 'solo', None)])[0]


def postflight(run):
    before = parse(snapshot(run / 'journal-before.json', 16384)['raw'])
    after = journal(device_directory()); require_empty(after, before)
    gate = run / 'gate.json'
    if gate.exists():
        acquired = parse(snapshot(gate, 65536)['raw'])
        require_empty(after, acquired)
    actual = processes(time.monotonic() + 4)
    require(not actual['prohibited'], 'A native/owner remains after reference')
    write_json(run / 'physical-postflight.json', dict(journal=after, processes=actual,
               inheritedGateObserved=gate.exists(), protocolReleaseACK=False))
