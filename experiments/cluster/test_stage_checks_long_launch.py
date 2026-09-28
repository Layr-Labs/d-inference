"""Public entry exercised with fake system/process/artifact services only."""
from contextlib import ExitStack, redirect_stdout
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from runtime.stage_checks import cli, long_cli, long_inputs
from runtime.stage_checks.common import canonical, digest, parse
from runtime.stage_checks.long_profile import ARTIFACT
from runtime.stage_checks.long_stream import WARNING
from stage_long_test_support import Child, rows, write_rows


class LongLaunchTests(unittest.TestCase):
    def setUp(self):
        for target in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard = patch(target, side_effect=AssertionError('No real process/socket calls')); guard.start(); self.addCleanup(guard.stop)
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup); self.base = Path(temp.name)
        self.runtime = self.base / 'repo/experiments/cluster/runtime'; self.runtime.mkdir(parents=True)
        self.release = self.base / 'release'; self.release.mkdir(); self.model = self.base / 'model'; self.model.mkdir()
        self.prompt = self.base / 'prompt.json'; self.prompt.write_bytes(b' \n' + canonical([3] * 8192) + b'\n')
        self.origin = self.base / 'origin.json'; self.origin.write_bytes(b'opaque independently pinned origin\n')
        self.config = b'{"syntheticTestMetadata":true}\n'; (self.model / 'config.json').write_bytes(self.config)
        manifest = dict(aggregate_sha256=ARTIFACT,total_size_bytes=1,
                        files=[dict(path='config.json',sha256=digest(self.config))])
        (self.model / 'manifest.json').write_bytes(canonical(manifest))
        self.binary = b'fabricated bytes, never executable'; self.events = []; self.stops = []; self.children = []

    def arguments(self, mode, output):
        args = [mode,'--runtime',str(self.runtime),'--output',str(output),'--release',str(self.release),
            '--expected-binary-sha256',digest(self.binary),'--model-dir',str(self.model),
            '--artifact-aggregate-sha256',ARTIFACT,'--tokens-file',str(self.prompt),
            '--tokens-sha256',digest(self.prompt.read_bytes()),'--prompt-origin-file',str(self.origin),
            '--prompt-origin-sha256',digest(self.origin.read_bytes())]
        if mode.endswith('ranks'): args += ['--stage-prefill-policy','serial_v1','--stage-logits-dtype','bfloat16']
        return args

    def execute(self, mode='long-prefill-ranks', refuse=False, post_failure=False):
        output = self.base / 'output'; outer = self
        class Gate:
            def __init__(self): self.samples = []
            def observe(self):
                outer.events.append('memory'); self.samples.append(dict(pressure_level=1,swap_used_bytes='0'))
        def initial(): self.events.append('initial'); return {'passed':not refuse}
        def source(_runtime, out):
            self.events.append('source'); (out / 'source-manifest.json').write_bytes(b'{}')
            base = out / 'source/experiments/cluster/inference/Sources/ClusterInference'; base.mkdir(parents=True)
            (base / 'Collective.swift').write_text('if transport == .loopbackTest {\n            log("' + WARNING.decode().rstrip('\n') + '")\n}')
            (base / 'Options.swift').write_text('func log(_ message: String) {\n    FileHandle.standardError.write(Data((message + "\\n").utf8))\n}')
            return {'files':[]}
        def snapshot(_release, out):
            self.events.append('bundle'); out.mkdir(); (out / 'cluster-inference').write_bytes(self.binary); return 'a' * 64
        def verify_model(*_args): self.events.append('artifact')
        def endpoints():
            self.events.append('ports')
            if mode.endswith('solo'): raise AssertionError('Solo must not allocate ports')
            return [['127.0.0.1:31001'],['127.0.0.1:31002']]
        def start(rank):
            self.events.append('start')
            actual = parse((Path(rank['local']) / 'rank.json').read_bytes())
            self.assertEqual(actual['input_files'], {}); self.assertEqual(actual['environment']['MLX_ENABLE_TF32'], '1')
            self.assertEqual((Path(rank['local']) / 'prompt.json').read_bytes(), self.prompt.read_bytes())
            ctx = parse((output / 'context.json').read_bytes()); write_rows(rank['local'], rows(rank['rank'], ctx), mode.endswith('ranks'))
            child = Child(rank['rank'], lambda:1, finish=0); self.children.append(child); return child
        def stop(owners, children): self.stops.append([rank['rank'] for rank in owners])
        modules = dict(bundle=SimpleNamespace(snapshot=snapshot), artifacts=SimpleNamespace(verify_model=verify_model),
            configuration=SimpleNamespace(loopback_addresses=endpoints), processes=SimpleNamespace(start=start,stop_processes=stop))
        def verify_archive(*_args):
            self.events.append('archive-check')
            if post_failure and self.children: raise ValueError('post-run source drift')
        with ExitStack() as stack:
            stack.enter_context(patch.object(long_cli,'initial_free_screen',side_effect=initial))
            stack.enter_context(patch.object(long_cli,'MemoryGate',Gate))
            stack.enter_context(patch.object(long_cli,'resource_preflight',return_value={'passed':True}))
            stack.enter_context(patch.object(long_inputs,'CONFIGURATION',digest(self.config)))
            stack.enter_context(patch.object(long_cli.archive,'archive_launcher',return_value=[]))
            stack.enter_context(patch.object(long_cli.archive,'archive_sources',side_effect=source))
            stack.enter_context(patch.object(long_cli.archive,'load_archived_runtime',return_value=modules))
            stack.enter_context(patch.object(long_cli.archive,'verify_archive',side_effect=verify_archive))
            stack.enter_context(redirect_stdout(io.StringIO()))
            code = cli.main(self.arguments(mode, output))
        return code, parse((output / 'receipt.json').read_bytes()), output

    def test_pair_entry_preserves_raw_files_and_scopes_before_after_checks(self):
        code, record, output = self.execute()
        self.assertEqual(code,0); self.assertTrue(record['passed']); self.assertEqual(self.events[:3], ['initial','memory','source'])
        self.assertEqual(self.events.count('artifact'),2); self.assertEqual(self.events.count('start'),2)
        self.assertLess(self.events.index('artifact'),self.events.index('start'))
        self.assertEqual(len(record['rank_files']),10); self.assertFalse(record['baseline_audit']['performed'])
        self.assertEqual((output / 'inputs/prompt-origin.json').read_bytes(), self.origin.read_bytes())

    def test_solo_entry_has_no_ports_epoch_or_transport_in_native_argv(self):
        code, record, output = self.execute(mode='long-prefill-solo')
        self.assertEqual(code,0); self.assertNotIn('ports',self.events); self.assertEqual(record['local_owner_count'],1)
        config = parse((output / 'rank-0/rank.json').read_bytes())
        for flag in ('--transport','--epoch','--stage-prefill-policy','--stage-logits-dtype'):
            self.assertNotIn(flag,config['arguments'])

    def test_initial_refusal_stops_before_snapshot_payload_hash_or_start(self):
        code, record, _output = self.execute(refuse=True)
        self.assertEqual(code,1); self.assertEqual(self.events,['initial']); self.assertFalse(record['native_execution_attempted'])

    def test_post_run_source_drift_keeps_native_completion_but_fails_run(self):
        code, record, _output = self.execute(post_failure=True)
        self.assertEqual(code,1); self.assertTrue(record['cohort']['passed']); self.assertFalse(record['passed'])
        self.assertIn('post-run source drift',record['primary_failure']['error']); self.assertEqual(self.stops,[[0,1]])


if __name__ == '__main__': unittest.main()
