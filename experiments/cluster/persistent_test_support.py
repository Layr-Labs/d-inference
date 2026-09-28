"""Real local-process fixtures for persistent cohort supervision tests."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


def wait_until(predicate, timeout=4, description='fixture condition'):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)
    raise AssertionError(f'Timed out waiting for {description}')


def process_running(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='],
                            capture_output=True, text=True, timeout=2)
    state = result.stdout.strip()
    return bool(state and not state.startswith('Z'))


class PersistentFixture:
    """Each test gets one executable snapshot source and independent audit files."""

    def __init__(self, actions=None):
        self.temporary = tempfile.TemporaryDirectory(prefix='persistent-failure-')
        self.root = Path(self.temporary.name)
        self.scenario = self.root / 'scenario.json'
        self.scenario.write_text(json.dumps(dict(actions=actions or {})))
        self.source = self.root / 'source'
        self.source.mkdir()
        script = Path(__file__).parent / 'test_fixtures' / 'fake_persistent_native.py'
        executable = f'#!{sys.executable}\nSCENARIO_PATH = {str(self.scenario)!r}\n' + script.read_text()
        (self.source / 'cluster-inference').write_text(executable)
        (self.source / 'cluster-inference').chmod(0o700)
        (self.source / 'mlx.metallib').write_text('CPU fixture, not a Metal library')
        resource = self.source / 'mlx-swift-lm_MLXLMCommon.bundle'
        resource.mkdir()
        (resource / 'fixture').write_text('CPU-only resource')
        self.output = self.root / 'run'

    def events(self, rank):
        path = self.root / f'events-{rank}.jsonl'
        if not path.exists():
            return []
        records = []
        for line in path.read_text().splitlines():
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                # An in-progress final write is retried by wait_until.
                continue
        return records

    def process_ids(self):
        result = []
        for rank in (0, 1):
            for event in self.events(rank):
                if event['event'] == 'loaded':
                    result.extend([event['pid'], event['descendant']])
        return result

    def wait_for_active(self, request_id, ranks=(0, 1)):
        return wait_until(lambda: all(any(e['event'] == 'infer' and e['request_id'] == request_id
                                         for e in self.events(rank)) for rank in ranks),
                          description=f'active request {request_id} on ranks {ranks}')

    def assert_stopped(self):
        pids = self.process_ids()
        if not pids:
            raise AssertionError('Fixture did not start; cannot establish process cleanup')
        wait_until(lambda: not any(process_running(pid) for pid in pids),
                   timeout=4, description=f'fixture processes to stop: {pids}')

    def cleanup(self):
        # Backstop only: tests assert cleanup before invoking this method.
        for pid in self.process_ids():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.temporary.cleanup()


def cohort_spec():
    return dict(schema_version=1, backend='loopback-test', partition='ffn',
                ranks=[dict(location='local'), dict(location='local')],
                workload=dict(synthetic=True, synthetic_profile='tiny', synthetic_dtype='float32',
                              prompt_tokens=4, chunk_size=3, decode_tokens=3,
                              warmups=0, repeats=1, seed=7), timeout_seconds=10)
