"""CPU subprocess fixture; SCENARIO_PATH is supplied by the test snapshot.

This implements the public JSONL wire contract, not the cohort implementation.
Every load starts an independently observable child in the native process group.
Faults deliberately leave it alive so supervision, rather than fixture cleanup,
must prove ownership retirement.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'),
                      ensure_ascii=False, allow_nan=False).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


parser = argparse.ArgumentParser(allow_abbrev=False)
parser.add_argument('--epoch', required=True)
parser.add_argument('--mode', required=True)
parser.add_argument('--partition', default='ffn')
parser.add_argument('--transport', default='none')
parser.add_argument('--synthetic-profile', default='tiny')
parser.add_argument('--synthetic-dtype', default='float32')
parser.add_argument('--attention-output-precision', default='native')
parser.add_argument('--ffn-branch-precision', default='native')
parser.add_argument('--seed', default='7')
parser.add_argument('--timeout-seconds', type=int, default=10)
options, _ = parser.parse_known_args()
directory = Path(SCENARIO_PATH).parent
rank = int(os.environ.get('MLX_RANK', '0'))
cooperative = options.mode == 'worker-tp'
load_id = str(uuid.uuid4())


def audit(event, **fields):
    with (directory / f'events-{rank}.jsonl').open('a') as stream:
        stream.write(json.dumps(dict(event=event, **fields)) + '\n')


def action():
    return json.loads(Path(SCENARIO_PATH).read_text())['actions'].get(str(rank), 'normal')


def emit(kind, **fields):
    frame = dict(version=3, type=kind, epoch=options.epoch, rank=rank, **fields)
    if kind == 'accepted' and action() == 'wrong_epoch':
        frame['epoch'] = '0' * 32
    print(canonical(frame).decode(), flush=True)


def hang():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)


descendant = subprocess.Popen(
    [sys.executable, '-c', 'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(120)'],
    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
audit('loaded', pid=os.getpid(), descendant=descendant.pid, model_load_id=load_id,
      epoch=options.epoch, mode=options.mode)
layouts = ['c' * 64, 'e' * 64] if cooperative else ['c' * 64]
gemma_profiles = {'gemma-moe': 'mixed-w4w8g64', 'gemma-moe-w8': 'w8g64'}
family = 'gemma4' if options.synthetic_profile in gemma_profiles else 'qwen35'
quantization = gemma_profiles.get(options.synthetic_profile, 'w4g64')
storage = dict(schemaVersion=1, sourceTensorManifestSHA256='b' * 64,
               sourceModelTensorBytes=1000, sourceFFNTensorBytes=800,
               sourceShardedFFNTensorBytes=600, sourceShardedTensorBytes=600,
               ranks=[dict(rank=i, parameterLayoutSHA256=layouts[i],
                           loadedTensorBytes=650 + i * 100,
                           selectedShardedTensorBytes=250 + i * 100) for i in range(2)]) if cooperative else None
identity = dict(
    model=f'synthetic-{family}-{quantization}-seed-' + options.seed,
    configurationSHA256='a' * 64, parameterLayoutSHA256s=layouts,
    modelFamily=family, partitionStorageSHA256=digest(storage) if cooperative else 'none',
    partition=options.partition if cooperative else 'none',
    partitionPlanSHA256='d' * 64 if cooperative else 'none',
    attentionOutputPrecision=options.attention_output_precision,
    ffnBranchPrecision=options.ffn_branch_precision,
    vocabularySize=512, layerCount=4,
    feedForwardKind='moe' if family == 'gemma4' or options.synthetic_profile == 'qwen-moe' else 'dense',
    embeddingActivationDType=options.synthetic_dtype, ffnScaleDTypes=[options.synthetic_dtype],
    syntheticWeights=True, syntheticDType=options.synthetic_dtype,
    syntheticProfile=options.synthetic_profile, seed=options.seed,
    bf16ConversionEnabled=False, verifiedAggregateSHA256='none',
    transport=options.transport if cooperative else 'none',
    tokenSelectionPolicy='rank0-greedy' if cooperative else 'local-greedy',
    textOnly=True, mtpEnabled=False)
limits = dict(maxContextTokens=32768, maxOutputTokens=4096, maxChunkSize=32768,
              maxTimeoutSeconds=300, maxRequestsPerEpoch=4096,
              maxCapturedLogitValues=1048576, maxLineBytes=2097152,
              idleTimeoutSeconds=options.timeout_seconds)
if action() == 'wrong_ready_identity':
    identity['configurationSHA256'] = 'b' * 64
if action() == 'wrong_ffn_precision':
    identity['ffnBranchPrecision'] = 'native' if options.ffn_branch_precision == 'float32' else 'float32'
if action() == 'hang_ready':
    hang()
extra_ready = dict(partitionStorage=storage) if cooperative else {}
emit('ready', worldSize=2 if cooperative else 1, pid=os.getpid(), modelLoadID=load_id,
     modelLoadCount=1, identity=identity, identitySHA256=digest(identity), limits=limits,
     parameterLayoutSHA256=layouts[rank], **extra_ready)

for line in sys.stdin:
    command = json.loads(line)
    if type(command.get('version')) is not int or command['version'] != 3:
        raise ValueError('The fake worker requires protocol version 3')
    fault = action()
    if command['type'] == 'shutdown':
        audit('shutdown', sequence=command['sequence'])
        if fault == 'hang_shutdown':
            hang()
        emit('stopped', sequence=command['sequence'])
        break
    sequence, request_id = command['sequence'], command['requestID']
    audit('infer', request_id=request_id, sequence=sequence, prompt=command['prompt'])
    common = dict(sequence=sequence, requestID=request_id)
    accepted = dict(**common, requestSHA256=digest(command), modelLoadID=load_id)
    if fault == 'wrong_request':
        accepted['requestID'] = 'not-the-active-request'
    if fault == 'wrong_hash':
        accepted['requestSHA256'] = 'f' * 64
    if fault == 'wrong_load':
        accepted['modelLoadID'] = str(uuid.uuid4())
    if fault == 'wrong_sequence':
        accepted['sequence'] = sequence + 1
    emit('accepted', **accepted)
    if fault == 'crash':
        os._exit(17)
    if fault == 'eof':
        os.close(sys.stdout.fileno())
        hang()
    if fault == 'hang_active':
        hang()
    generated = [3 + (sum(command['prompt']) * 3 + step) % 509
                 for step in range(command['outputTokens'])]
    for step, token in enumerate(generated):
        if fault == 'wrong_token' and step == 1:
            token = (token + 1) % 512
        if fault == 'wrong_token_request' and step == 1:
            emit('token', sequence=sequence, requestID='stale-request', step=step, token=token)
        else:
            emit('token', **common, step=step, token=token)
    if fault == 'missing_completed':
        hang()
    steps = [0.01] * (len(generated) - 1)
    elapsed = sum(steps)
    result = dict(iteration=sequence, promptTokens=len(command['prompt']),
                  generatedTokens=generated, localArgmaxTokens=generated,
                  localArgmaxDisagreementCount=0,
                  decodeInputTokens=command.get('teacherTokens', generated[:-1]),
                  prefillSeconds=0.02, prefillTokensPerSecond=len(command['prompt']) / 0.02,
                  decodeForwardCount=len(steps), decodeSeconds=elapsed,
                  decodeStepSeconds=steps, peakMLXBytes=8192, activeMLXBytes=4096)
    if steps:
        result['decodeTokensPerSecond'] = len(steps) / elapsed
    completed = dict(**common, requestSHA256=digest(command), modelLoadID=load_id, result=result)
    if command['captureLogits']:
        completed['logits'] = [[float(index == token) for index in range(512)] for token in generated]
    if fault == 'wrong_completed_request':
        completed['requestID'] = 'stale-request'
    if fault == 'wrong_completed_load':
        completed['modelLoadID'] = str(uuid.uuid4())
    emit('completed', **completed)
    audit('completed', request_id=request_id, sequence=sequence)

audit('exit')
