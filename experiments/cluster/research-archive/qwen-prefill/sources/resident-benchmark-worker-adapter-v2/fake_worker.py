"""Invented pipe peer used only by tests; no model or native executable."""

import json
import sys
import time
import uuid

mode, role, rank_text = sys.argv[1:4]
rank = None if rank_text == 'none' else int(rank_text)
opened = json.loads(sys.stdin.readline())


def emit(kind, record):
    value = dict(schema=opened['schema'], type=kind, cohort_id=opened['cohort_id'], role=role, rank=rank, record=record)
    if mode == 'wrong-role':
        value['role'] = 'other'
    raw = json.dumps(value, separators=(',', ':'))
    if mode == 'duplicate-key':
        raw = raw.replace('"type":', '"type":"other","type":', 1)
    sys.stdout.write(raw + '\n')
    sys.stdout.flush()


if mode == 'hang-open':
    time.sleep(60)
if mode == 'stderr':
    sys.stderr.write('invented diagnostic\n'); sys.stderr.flush()
if mode == 'exit-enter':
    raise SystemExit(3)
emit('ready', dict(execution={}, initialResources={}, loadedResources={}, runtime={}))
if mode == 'early-result':
    first = opened['requests'][0]
    early = dict(schema=opened['schema'], type='run', cohort_id=opened['cohort_id'], sequence=1, **first)
    emit('result', dict(command=early, step={}, execution={}, resourcesBeforeRequest={}, resourcesAfterRequest={}))
for line in sys.stdin:
    command = json.loads(line)
    if command['type'] == 'run':
        if mode == 'hang-run':
            time.sleep(60)
        if mode == 'incomplete':
            sys.stdout.write('{"truncated":true}'); sys.stdout.flush(); raise SystemExit(0)
        if mode == 'large':
            sys.stdout.write('x' * 4096 + '\n'); sys.stdout.flush(); raise SystemExit(0)
        if mode == 'wrong-command':
            command['epoch'] = 'f' * 32
        ordinal = command['sequence'] - 1
        step = dict(ordinal=ordinal, excludedWarmup=ordinal == 0,
                    requestID=str(uuid.UUID(command['epoch'])), recordedRequestFingerprint='a' * 64,
                    promptFileSHA256='b' * 64)
        emit('result', dict(command=command, step=step, execution=dict(elapsed_ns=1000000000, selection=1),
                            resourcesBeforeRequest=None if mode == 'null-resources' else {}, resourcesAfterRequest={}))
        if command['sequence'] == 4:
            if mode == 'missing-release':
                raise SystemExit(0)
            emit('released', dict(completedRequestCount=4, modelReleased=True))
    elif command['type'] == 'shutdown':
        emit('stopped', dict(completedRequestCount=4, explicitShutdownAccepted=True))
        if mode == 'trailing':
            emit('stopped', {})
        raise SystemExit(4 if mode == 'nonzero-exit' else 0)
    else:
        raise SystemExit(5)
