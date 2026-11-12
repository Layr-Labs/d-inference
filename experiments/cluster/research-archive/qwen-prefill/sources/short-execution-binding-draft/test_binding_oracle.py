"""Isolated fixed-source oracle regressions; no real numerical candidate replay."""

import builtins
from contextlib import contextmanager
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import uuid

import binding_oracle


NAMES = ('stage_load_contract', 'short_parity_contract', 'recorded_math', 'audit_short_parity')
ABSENT = object()


@contextmanager
def isolated_oracle():
    """Run the real loader on disposable copies and restore all shared slots."""
    previous = {name:sys.modules.get(name, ABSENT) for name in NAMES}
    for name in NAMES:
        sys.modules.pop(name, None)
    temporary = tempfile.TemporaryDirectory(prefix='binding-oracle-test-')
    module = None
    try:
        root = Path(temporary.name); (root / 'oracle').mkdir()
        for name in binding_oracle.PINS:
            shutil.copyfile(binding_oracle.HERE / 'oracle' / name, root / 'oracle' / name)
        spec = importlib.util.spec_from_file_location('_isolated_binding_' + uuid.uuid4().hex,
                                                     binding_oracle.__file__)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.HERE = root
        yield module, root
    finally:
        if module is not None and module._OWNED_DIRECTORY is not None:
            module._OWNED_DIRECTORY.cleanup()
        for name, value in previous.items():
            sys.modules.pop(name, None)
            if value is not ABSENT:
                sys.modules[name] = value
        temporary.cleanup()


class BindingOracleTests(unittest.TestCase):
    def test_real_four_source_load_uses_private_sibling_copy_and_reuses_objects(self):
        with isolated_oracle() as (module, root):
            original = Path.read_bytes; reads = []

            def read(path):
                self.assertNotEqual(path.parent.resolve(), (root / 'oracle').resolve(),
                                    'import reopened the checked original source')
                reads.append(path)
                return original(path)

            with patch.object(Path, 'read_bytes', read):
                first, contract = module.load()
            self.assertEqual(set(module._MODULES), set(NAMES))
            owned = Path(module._OWNED_DIRECTORY.name)
            self.assertEqual(stat.S_IMODE(owned.stat().st_mode), 0o700)
            # Resolve only these disposable test paths: macOS aliases /var to /private/var.
            self.assertIn((owned / 'stage_load_contract.py').resolve(), [p.resolve() for p in reads])
            for name in NAMES:
                path = Path(module._MODULES[name].__file__)
                self.assertEqual(path.parent, owned)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o400)
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), module.PINS[path.name])
            again, again_contract = module.load()
            self.assertIs(again, first); self.assertIs(again_contract, contract)

    def test_source_replaced_after_capture_never_executes_replacement(self):
        with isolated_oracle() as (module, root):
            original = module.snapshot; count = 0
            marker = '_short_binding_test_unchecked_code_executed'
            malicious = ('import builtins\nbuiltins.' + marker + ' = True\n').encode()

            def capture(path, *args, **kwargs):
                nonlocal count
                value = original(path, *args, **kwargs)
                count += 1
                if count == len(module.PINS):
                    (root / 'oracle' / 'audit_short_parity.py').write_bytes(malicious)
                return value

            with patch.object(builtins, marker, False, create=True), \
                    patch.object(module, 'snapshot', capture):
                with self.assertRaisesRegex(ValueError, 'Frozen oracle changed during import'):
                    module.load()
                self.assertIs(getattr(builtins, marker), False)
                self.assertTrue(callable(module._MODULES['audit_short_parity'].audit))

    def test_altered_source_refused_before_installing_any_oracle(self):
        for filename in binding_oracle.PINS:
            with self.subTest(filename=filename), isolated_oracle() as (module, root):
                target = root / 'oracle' / filename
                target.write_bytes(target.read_bytes() + b'\n# changed\n')
                with self.assertRaisesRegex(ValueError, 'Frozen oracle changed'):
                    module.load()
                self.assertEqual(module._MODULES, {})
                self.assertTrue(all(name not in sys.modules for name in NAMES))

    def test_preexisting_same_file_label_does_not_authorize_module(self):
        with isolated_oracle() as (module, root):
            impostor = types.ModuleType('audit_short_parity')
            impostor.__file__ = str(root / 'oracle' / 'audit_short_parity.py')
            sys.modules['audit_short_parity'] = impostor
            with self.assertRaisesRegex(ValueError, 'Conflicting oracle module'):
                module.load()
            self.assertEqual(module._MODULES, {})

    def test_cached_module_replacement_with_same_file_is_refused(self):
        with isolated_oracle() as (module, _):
            module.load()
            original = sys.modules['recorded_math']
            impostor = types.ModuleType('recorded_math'); impostor.__file__ = original.__file__
            sys.modules['recorded_math'] = impostor
            with self.assertRaisesRegex(ValueError, 'Oracle module identity changed'):
                module.load()
            sys.modules['recorded_math'] = original
            self.assertIs(module.load()[0], module._MODULES['audit_short_parity'])

    def test_owned_copy_tampering_is_refused_even_with_original_sources_intact(self):
        with isolated_oracle() as (module, _):
            module.load()
            path = Path(module._OWNED_DIRECTORY.name) / 'stage_load_contract.py'
            path.chmod(0o600); path.write_bytes(path.read_bytes() + b'\n# changed owned copy\n')
            with self.assertRaisesRegex(ValueError, 'Owned oracle snapshot changed'):
                module.load()

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'requires POSIX FIFO')
    def test_metadata_reader_receives_owned_bytes_after_caller_fifo_replacement(self):
        with isolated_oracle() as (module, root):
            raw = b'{"fabricated":true}'
            caller = root / 'caller-metadata.json'; caller.write_bytes(raw)
            core = {'retained_metadata': {'raw':raw, 'path':str(caller)}, 'stdout': {'raw':b'fabricated\n'}}
            caller.unlink(); os.mkfifo(caller, 0o600)
            seen = []

            def old_path_reader(stdout, profile, token_metadata, fixture):
                path = Path(fixture)
                self.assertNotEqual(path, caller)
                self.assertTrue(stat.S_ISREG(path.stat().st_mode))
                self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o400)
                self.assertEqual(path.read_bytes(), raw)
                self.assertEqual(stdout, b'fabricated\n')
                seen.append(path)
                return {'fabricatedReaderCalled': True}

            fake = types.SimpleNamespace(FIXTURE_SHA=hashlib.sha256(raw).hexdigest(), audit=old_path_reader)
            with patch.object(module, 'load', return_value=(fake, None)):
                self.assertEqual(module.replay(core, 'fabricated', {}), {'fabricatedReaderCalled': True})
            self.assertEqual(len(seen), 1)
            self.assertFalse(seen[0].parent.exists())
            self.assertTrue(stat.S_ISFIFO(caller.stat().st_mode))

    def test_metadata_error_cleans_owned_copy_and_bad_pin_never_calls_reader(self):
        with isolated_oracle() as (module, _):
            raw = b'{}'; seen = []

            def rejecting_reader(stdout, profile, token_metadata, fixture):
                seen.append(Path(fixture))
                raise ValueError('fabricated oracle refusal')

            fake = types.SimpleNamespace(FIXTURE_SHA=hashlib.sha256(raw).hexdigest(), audit=rejecting_reader)
            core = {'retained_metadata': {'raw': raw}, 'stdout': {'raw': b'fake'}}
            with patch.object(module, 'load', return_value=(fake, None)):
                with self.assertRaisesRegex(ValueError, 'fabricated oracle refusal'):
                    module.replay(core, 'fabricated', {})
                self.assertFalse(seen[0].parent.exists())
                core['retained_metadata']['raw'] = b'[]'
                with self.assertRaisesRegex(ValueError, 'Registered metadata bytes differ'):
                    module.replay(core, 'fabricated', {})
            self.assertEqual(len(seen), 1)


if __name__ == '__main__':
    unittest.main()
