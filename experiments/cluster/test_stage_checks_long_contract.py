"""Pure long-profile source/identity/raw-byte admission checks."""
import copy
import io
import tempfile
from contextlib import redirect_stderr
from pathlib import Path
import unittest
from unittest.mock import patch
from runtime.stage_checks import cli, long_configuration, long_inputs, long_rank_contract, long_solo_contract
from runtime.stage_checks.common import canonical, digest
from runtime.stage_checks.long_profile import ARTIFACT
from runtime.stage_checks.long_resources import MemoryGate
from runtime.stage_checks.long_stream import Records, WARNING, source_stderr_contract
from runtime.stage_checks.long_identity import recorded_request
from stage_long_test_support import EPOCH, context, rows, write_rows


class LongContractTests(unittest.TestCase):
    def setUp(self):
        for name in ('subprocess.Popen','subprocess.run','socket.socket'):
            guard = patch(name, side_effect=AssertionError('No real process/socket calls')); guard.start(); self.addCleanup(guard.stop)
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup); self.base = Path(temp.name)

    def test_exact_raw_prompt_and_strict_integer_lexemes(self):
        raw = b' \n' + canonical([3] * 8192) + b'\n '
        self.assertEqual(long_inputs.prompt_ids(raw), [3] * 8192)
        for bad in (b'-0', b'3.0', b'3e0', b'true', b'null', b'NaN', b'248320'):
            with self.subTest(bad=bad), self.assertRaises((ValueError, TypeError)):
                long_inputs.prompt_ids(b'[' + bad + b',' + b','.join([b'3'] * 8191) + b']')
        for raw in (canonical([3] * 8191), canonical([3] * 8193), b' ' * 65537):
            with self.assertRaises(ValueError): long_inputs.prompt_ids(raw)

    def test_paired_and_solo_configurations_keep_raw_staging(self):
        for mode in ('long-prefill-ranks','long-prefill-solo'):
            ctx = context(mode); paired = mode.endswith('ranks'); hosts = [['127.0.0.1:30101'],['127.0.0.1:30102']] if paired else None
            for rank in range(2 if paired else 1):
                config = long_configuration.build(rank, ctx, '/unused-bundle', 'c' * 64, hosts)
                self.assertEqual(config['input_files'], {}); self.assertFalse(config['persistent'])
                args = config['arguments']; self.assertIn('--long-prompt-sha256', args)
                self.assertEqual(args[args.index('--seed') + 1], '7'); self.assertEqual(config['timeout_seconds'], 300)
                self.assertEqual('--transport' in args, paired); self.assertEqual('MLX_RANK' in config['environment'], paired)
                self.assertEqual(config['environment_files'], {'MLX_HOSTFILE':'hosts.json'} if paired else {})

    def test_invalid_policy_transport_rank_and_source_are_rejected(self):
        hosts = [['127.0.0.1:30101'],['127.0.0.1:30102']]
        for key, value in [('stage_prefill_policy','lookahead-one'),('stage_logits_dtype','float32'),('artifact','0' * 64),('epoch','bad')]:
            ctx = context(); ctx[key] = value
            with self.assertRaises(ValueError): long_configuration.build(0, ctx, '/unused', 'a' * 64, hosts)
        for bad in ([['localhost:30101'],['127.0.0.1:30102']], [['127.0.0.1:0301'],['127.0.0.1:30102']], [hosts[0],hosts[0]]):
            with self.assertRaises(ValueError): long_configuration.build(0, context(), '/unused', 'a' * 64, bad)
        with self.assertRaises(ValueError): long_configuration.build(1, context('long-prefill-solo'), '/unused', 'a' * 64, None)

    def test_staged_prompt_and_hosts_are_exact_bytes(self):
        folder = self.base / 'inputs'; folder.mkdir(); raw = b' ' + canonical([3] * 8192) + b'\n'
        (folder / 'prompt.json').write_bytes(raw); ctx = context(); ctx['prompt_file_sha256'] = digest(raw)
        owners, records = long_configuration.stage(self.base, ctx, 'a' * 64, [['127.0.0.1:30101'],['127.0.0.1:30102']])
        self.assertEqual(len(owners), 2); self.assertEqual(len(records), 6)
        for owner in owners:
            self.assertIsNone(owner['host']); self.assertEqual((Path(owner['local']) / 'prompt.json').read_bytes(), raw)
            self.assertEqual((Path(owner['local']) / 'prompt.json').stat().st_mode & 0o777, 0o400)

    def test_valid_outer_contracts_and_wrong_namespaces(self):
        for mode in ('long-prefill-ranks','long-prefill-solo'):
            ctx = context(mode); values = rows(0, ctx); directory = self.base / mode; directory.mkdir()
            write_rows(directory, values, mode.endswith('ranks')); reader = Records(directory, 0, ctx); reader.poll(final=True)
            self.assertEqual(len(reader.rows), 2)
            values[0]['schemaVersion'] = 1.0; write_rows(directory, values, mode.endswith('ranks'))
            with self.assertRaises(ValueError): Records(directory, 0, ctx).poll(final=True)

    def test_v4_identity_mutations_fail_closed(self):
        ctx = context()
        for key, value in [('epoch','b' * 32),('envelopeVersion',3),('promptFileSHA256','c' * 64),('rank',1),
                           ('flow','bounded_prefill_measurement_v1'),('freshRequestStateCreated',True)]:
            ready = rows()[0]; ready[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): long_rank_contract.validate(ready, 0, 0, EPOCH, 'serial_v1', ctx)
        ready, final = rows(); final['request']['steps'][7]['tokenIDs'][0] = 4
        with self.assertRaises(ValueError): long_rank_contract.validate(final, 1, 0, EPOCH, 'serial_v1', ctx, ready)

    def test_solo_source_environment_and_ready_history_are_bound(self):
        ctx = context('long-prefill-solo')
        for change in ('source','environment','history','flag'):
            ready, final = rows(0, ctx)
            if change == 'source': final['execution']['source']['artifactAggregateSHA256'] = '0' * 64
            if change == 'environment': final['arithmeticEnvironment']['requiredValues']['MLX_ENABLE_TF32'] = '0'
            if change == 'history': ready['recordedRequestFingerprint'] = '0' * 64
            if change == 'flag': final['throughputMeasurementValid'] = True
            with self.subTest(change=change), self.assertRaises(ValueError): long_solo_contract.validate(final, 1, ctx, ready)

    def test_solo_native_request_uuid_is_independent_from_controller_epoch(self):
        ctx = context('long-prefill-solo'); ready, final = rows(0, ctx)
        native = recorded_request('c' * 32, ctx['prompt'])
        ready['recordedRequestFingerprint'] = native['fingerprint']; final['execution']['request'] = native
        long_solo_contract.validate(final, 1, ctx, ready)

    def test_loaded_stage_cannot_change_its_admitted_construction_identity(self):
        ctx = context(); ready, final = rows()
        final['sourceLoad']['constructionConfigurationSHA256'] = 'd' * 64
        with self.assertRaises(ValueError): long_rank_contract.validate(final, 1, 0, EPOCH, 'serial_v1', ctx, ready)

    def test_exact_stderr_partial_then_final_and_no_extras(self):
        values = rows(); write_rows(self.base, values)
        error = self.base / 'stderr.log'; error.write_bytes(WARNING[:10]); reader = Records(self.base, 0, context())
        reader.poll(); error.write_bytes(WARNING); reader.poll(final=True)
        for bad in (b'', WARNING + b'\n', b'prefix' + WARNING, WARNING * 2):
            error.write_bytes(bad)
            with self.assertRaises(ValueError): Records(self.base, 0, context()).poll(final=True)

    def test_duplicate_keys_nonfinite_partial_eof_and_extra_rows_fail(self):
        write_rows(self.base, rows()); path = self.base / 'stdout.jsonl'; valid = path.read_bytes()
        for raw in (valid.replace(b'"schemaVersion":1', b'"schemaVersion":1,"schemaVersion":1', 1),
                    valid.replace(b'"schemaVersion":1', b'"schemaVersion":NaN', 1), valid[:-1], valid + b'{}\n'):
            path.write_bytes(raw)
            with self.assertRaises(ValueError): Records(self.base, 0, context()).poll(final=True)

    def test_zero_swap_resource_gate_retains_failed_sample(self):
        for swap in ('0','1','NaN'):
            gate = MemoryGate(sample=lambda:dict(pressure_level=1, swap_used_bytes=swap))
            if swap == '0': gate.observe()
            else:
                with self.assertRaises(ValueError): gate.observe()
            self.assertEqual(len(gate.samples), 1)

    def test_bounded_metadata_reread_rejects_growth_before_reading_contents(self):
        path = self.base / 'metadata.json'; path.write_bytes(b'{}')
        self.assertEqual(long_inputs.bounded_bytes(path, 2), b'{}')
        path.write_bytes(b'{} ')
        with self.assertRaises(ValueError): long_inputs.bounded_bytes(path, 2)
        path.write_bytes(b'')
        with self.assertRaises(ValueError): long_inputs.bounded_bytes(path, 2)

    def test_parser_keeps_legacy_caps_and_requires_long_explicit_pins(self):
        with redirect_stderr(io.StringIO()):
            for command in ('long-prefill-ranks','long-prefill-solo'):
                with self.assertRaises(SystemExit): cli.parser().parse_args([command])
        names = cli.parser()._subparsers._group_actions[0].choices
        self.assertEqual(set(names), {'p2p','ranks','prefill-ranks','long-prefill-ranks','long-prefill-solo'})
        for name, seconds in [('p2p',60),('ranks',180),('prefill-ranks',180)]:
            self.assertEqual(names[name].get_default('timeout_seconds'), seconds)


if __name__ == '__main__': unittest.main()
