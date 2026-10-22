"""Fixed v3 prefill rank arguments and outer-only peer/record admission."""
import hashlib
import json
from pathlib import Path
import re
import uuid
from prefill_compute_contract import parse, require, timeout, flags, validate_request, MAX_STDOUT, MAX_LINE
from prefill_compute_inputs import ARTIFACT, CONFIGURATION, VOCABULARY, request_fingerprint, recorded_fingerprint

FLOW = 'bounded_prefill_measurement_v1'
POLICIES = ('serial_v1', 'prompt_lookahead_one_v1')
READY = 'qwen_layer_stage_prefill_rank_ready'
FINAL = 'qwen_layer_stage_prefill_rank_report'


def policy(value):
    require(value in POLICIES, 'Explicit supported stage-prefill-policy required')
    return value


def hostfile(value):
    require(isinstance(value, list) and len(value) == 2, 'Two loopback endpoints required')
    for row in value:
        require(isinstance(row, list) and len(row) == 1 and isinstance(row[0], str), 'Invalid loopback row')
        match = re.fullmatch(r'127\.0\.0\.1:(\d+)', row[0])
        require(match is not None and 1 <= int(match[1]) <= 65535 and str(int(match[1])) == match[1], 'Invalid loopback endpoint')
    require(value[0] != value[1], 'Loopback ports must differ')
    return value


def configuration(bundle, bundle_hash, model, prompt, seconds, rank, epoch, scheduling, endpoints):
    timeout(seconds); policy(scheduling); hostfile(endpoints)
    require(type(rank) is int and rank in (0, 1) and re.fullmatch('[0-9a-f]{32}', epoch) is not None, 'Invalid rank/epoch')
    require(len(prompt) == 65 and all(type(x) is int and 0 <= x < VOCABULARY for x in prompt), 'Wrong fixed prompt')
    return dict(bundle=str(bundle), bundle_sha256=bundle_hash, rank=rank, persistent=False,
        model_directory=str(model), artifact_aggregate_sha256=ARTIFACT, timeout_seconds=seconds,
        environment={'DARKBLOOM_BF16_WEIGHTS': '1', 'MLX_RANK': str(rank)},
        environment_files={'MLX_HOSTFILE': 'hosts.json'}, input_files={'prompt.json': prompt, 'hosts.json': endpoints},
        arguments=['--mode', 'qwen-layer-stage-prefill-rank-check', '--model-dir', '@model',
            '--artifact-aggregate-sha256', ARTIFACT, '--transport', 'loopback-test', '--epoch', epoch,
            '--execution-path', 'cbv2-contiguous', '--stage-prefill-policy', scheduling,
            '--stage-logits-dtype', 'bfloat16', '--tokens-file', '@rank/prompt.json',
            '--prompt-tokens', '65', '--chunk-size', '32', '--decode-tokens', '1',
            '--repeats', '1', '--warmups', '0', '--timeout-seconds', str(seconds)])


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def agreement(record, epoch, scheduling, prompt):
    value = record.get('agreement'); require(isinstance(value, dict), 'Missing shared agreement')
    known = dict(version=3, flow=FLOW, schedulingPolicy=scheduling, epoch=epoch,
        requestID=str(uuid.UUID(hex=epoch)), requestFingerprint=request_fingerprint(epoch),
        recordedRequestFingerprint=recorded_fingerprint(epoch, prompt), promptCount=65, chunkSize=32,
        outputCount=1, batchSize=1, frameCount=3, vocabularySize=VOCABULARY,
        promptTokenIDsSHA256=hashlib.sha256(','.join(map(str, prompt)).encode()).hexdigest(),
        sourceConfigurationSHA256=CONFIGURATION, artifactAggregateSHA256=ARTIFACT,
        bf16ConversionEnabled=True, nativeDType='bfloat16', logitsDType='bfloat16',
        selectionPolicy='mlx_argmax_all_axes_with_finite_guard_v1')
    for key, expected in known.items():
        require(type(value.get(key)) is type(expected) and value[key] == expected, 'Agreement field differs: ' + key)
    for key in ('storageCommitmentSHA256', 'planFingerprint', 'producerStageFingerprint', 'consumerStageFingerprint',
                'producerConstructionConfigurationSHA256', 'consumerConstructionConfigurationSHA256'):
        require(isinstance(value.get(key), str) and re.fullmatch('[0-9a-f]{64}', value[key]) is not None, 'Invalid agreement hash: ' + key)
    require(type(value.get('hiddenSize')) is int and 1 <= value['hiddenSize'] <= 8192, 'Invalid hidden size')
    expected = hashlib.sha256(b'qwen-prefill-start-agreement-v1\n' + canonical(value)).hexdigest()
    require(record.get('agreementFingerprint') == expected, 'Agreement fingerprint differs')


def validate(record, index, rank, epoch, scheduling, prompt, first=None):
    require(isinstance(record, dict), 'Rank record must be an object')
    for key, expected in dict(kind=READY if index == 0 else FINAL, schemaVersion=1, epoch=epoch, rank=rank,
            worldSize=2, transport='loopback-test', backend='ring', flow=FLOW, envelopeVersion=3).items():
        require(type(record.get(key)) is type(expected) and record[key] == expected, 'Rank record identity differs: ' + key)
    agreement(record, epoch, scheduling, prompt)
    if index == 0:
        flags(record, modelsReadyAgreementValidated=True, freshRequestStateCreated=False)
        return
    flags(record, completed=True, correctnessOnly=True, throughputMeasurementValid=False,
          modelForwardCompared=False, physicalTransferQualified=False, allRequestStateRetired=True, modelReleased=True)
    require(first is not None and record['agreement'] == first['agreement']
            and record['agreementFingerprint'] == first['agreementFingerprint'], 'Final rank agreement changed')
    validate_request(record.get('request'), prompt)
    require(str(uuid.UUID(record['request']['request']['requestID'])) == str(uuid.UUID(hex=epoch)), 'Request UUID differs from epoch')
    source = record.get('sourceLoad'); require(isinstance(source, dict) and source, 'Missing verified source receipt')
    require(source.get('verifiedAggregateSHA256') == ARTIFACT and source.get('sourceConfigurationSHA256') == CONFIGURATION,
            'Source load pins differ')
    result = record.get('execution')
    require(isinstance(result, dict) and result, 'Missing opaque native execution result')
    # Actions, frame/state/logit receipts and timing arithmetic belong to the
    # separate independent CPU oracle, not this launcher admission.


class Records:
    def __init__(self, directory, rank, epoch, scheduling, prompt):
        self.directory, self.rank, self.epoch, self.scheduling, self.prompt = Path(directory), rank, epoch, scheduling, prompt
        self.offset, self.pending, self.rows = 0, b'', []

    def poll(self, final=False):
        error, path = self.directory / 'stderr.log', self.directory / 'stdout.jsonl'
        require(not error.exists() or error.stat().st_size <= 4 * 1024**2, 'Rank stderr exceeds bound')
        size = path.stat().st_size if path.exists() else 0
        require(self.offset <= size <= MAX_STDOUT, 'Rank stdout shrank/exceeded bound')
        if size > self.offset:
            with path.open('rb') as stream:
                stream.seek(self.offset); chunk = stream.read(MAX_STDOUT - self.offset + 1)
            self.offset += len(chunk); self.pending += chunk
            require(self.offset <= MAX_STDOUT, 'Growing stdout exceeded bound')
        while b'\n' in self.pending:
            raw, self.pending = self.pending.split(b'\n', 1)
            require(raw and len(raw) <= MAX_LINE and len(self.rows) < 2, 'Invalid record length/count')
            row = parse(raw)
            validate(row, len(self.rows), self.rank, self.epoch, self.scheduling, self.prompt, self.rows[0] if self.rows else None)
            self.rows.append(row)
        require(len(self.pending) <= MAX_LINE, 'Partial rank record exceeds bound')
        if final:
            require(not self.pending and len(self.rows) == 2, 'EOF without both complete rank records')


def peers(readers):
    if all(reader.rows for reader in readers):
        require(readers[0].rows[0]['agreement'] == readers[1].rows[0]['agreement']
                and readers[0].rows[0]['agreementFingerprint'] == readers[1].rows[0]['agreementFingerprint'], 'Peers disagree on shared agreement')
