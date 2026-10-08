"""Fabricated protocol values, processed by the unchanged frozen client parser."""
import hashlib
import json
from pathlib import Path
import sys

HARNESS = Path(__file__).resolve().parents[1]
CLIENT = HARNESS.parent / 'installed-http-client-draft-20260915/client.py'
sys.path.insert(0, str(HARNESS))
from warmup_inputs import client_files
client_files(CLIENT)
sys.path.insert(0, str(CLIENT.parent))
from client_observation import ContentObservation


def receipt(prompt='fixture', count=512, outputs=128, finish='length', content=True,
            missed=False):
    observation = ContentObservation('Qwen3.5-9B')

    def send(choices, elapsed, usage=None):
        value = dict(id='fake-cpu-request', object='chat.completion.chunk',
                     model='Qwen3.5-9B', choices=choices)
        if usage is not None:
            value['usage'] = usage
        observation.accept(json.dumps(value), elapsed)

    send([dict(index=0, delta=dict(role='assistant'), finish_reason=None)], 1)
    if content:
        send([dict(index=0, delta=dict(content='answer'), finish_reason=None)],
             20_000_000_000 if missed else 100)
    send([dict(index=0, delta={}, finish_reason=finish)], 20_000_000_001)
    send([], 20_000_000_002,
         dict(prompt_tokens=count, completion_tokens=outputs, total_tokens=count+outputs))
    observation.accept('[DONE]', 20_000_000_003)
    return dict(schema='installed_external_content_client_v1', model='Qwen3.5-9B',
        prompt_utf8_sha256=hashlib.sha256(prompt.encode()).hexdigest(),
        request_settings=dict(max_tokens=128, enable_thinking=False, reasoning_parser='qwen3',
                              temperature=0, top_p=1, top_k=0, repetition_penalty=1,
                              presence_penalty=0, frequency_penalty=0),
        http_status=200, capture_complete=True,
        measurement=observation.content_summary(20_000_000_004, count, content),
        status='no_content' if not content else 'content_deadline_missed' if missed else 'completed',
        error=None if content else dict(type='ClientOutcome', code='no_content'))
