"""Small source/temporary-file checks; no SSH, native process or payload access."""
import argparse
import ast
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent
BASE = Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-windowed-state-supervisor-20260916')
sys.path.insert(0, str(BASE/'package'))
from target_inputs import Pins


def load_entry():
    spec = importlib.util.spec_from_file_location('retry_fixture_entry', ROOT/'package/run_target.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parser_for(path, arguments):
    tree = ast.parse(path.read_text())
    main = next(x for x in tree.body if isinstance(x, ast.FunctionDef) and x.name == 'main')
    body = []
    for node in main.body:
        body.append(node)
        if isinstance(node, ast.Assign) and any(isinstance(x, ast.Name) and x.id == 'args' for x in node.targets):
            break
    function = ast.FunctionDef(name='parse_fixture', args=ast.arguments(posonlyargs=[], args=[ast.arg(arg='arguments')],
        kwonlyargs=[], kw_defaults=[], defaults=[]), body=body+[ast.Return(ast.Name(id='args', ctx=ast.Load()))], decorator_list=[])
    code = ast.fix_missing_locations(ast.Module(body=[function], type_ignores=[]))
    namespace = dict(argparse=argparse, JOBS=dict(window=None, session=None, target=None))
    exec(compile(code, str(path), 'exec'), namespace)
    if path.name == 'run_physical.py':
        # Its unchanged public main reads sys.argv; the extracted prefix remains exact.
        previous = sys.argv
        try:
            sys.argv = [str(path), *arguments]
            return namespace['parse_fixture'](arguments)
        finally:
            sys.argv = previous
    return namespace['parse_fixture'](arguments)


class StopAtPins(Exception):
    pass


class RetryChecks(unittest.TestCase):
    def test_original_five_preimages_match_frozen_manifest(self):
        raw = (BASE/'manifest.json').read_bytes()
        lineage = json.loads((ROOT/'lineage.json').read_bytes())
        self.assertEqual(hashlib.sha256(raw).hexdigest(), lineage['baseManifestSHA256'])
        rows = {x['path']:x for x in json.loads(raw)['files']}
        for path in (ROOT/'originals').rglob('*.py'):
            relative = str(path.relative_to(ROOT/'originals'))
            self.assertEqual(path.read_bytes(), (BASE/relative).read_bytes())
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), rows[relative]['sha256'])

    def test_bounded_entry_arguments(self):
        for fixture in ('window', 'session', 'target'):
            args = ['--fixture', fixture, '--package-sha256', '0'*64, '--entrypoint-sha256', '1'*64]
            self.assertEqual(parser_for(ROOT/'package/run_target.py', args).attempt, 1)
            for value in range(1, 10):
                self.assertEqual(parser_for(ROOT/'package/run_target.py', args+['--attempt', str(value)]).attempt, value)
            for value in ('0', '10', '-1', '1.0', '../2'):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    parser_for(ROOT/'package/run_target.py', args+['--attempt', value])

    def test_outer_argument_bounds(self):
        for action in ('run', 'collect'):
            self.assertEqual(parser_for(ROOT/'run_physical.py', [action, '--fixture', 'window']).attempt, 1)
            self.assertEqual(parser_for(ROOT/'run_physical.py', [action, '--fixture', 'target', '--attempt', '2']).attempt, 2)
            for value in ('0', '10', '../2'):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    parser_for(ROOT/'run_physical.py', [action, '--fixture', 'window', '--attempt', value])

    def temporary_entry(self, root):
        module = load_entry()
        module.ROOT = root
        module.ENTRYPOINT = root/'operations-retry-20260916/run_target.py'
        module.REMOTE = str(root)
        module.platform = types.SimpleNamespace(system=lambda:'Darwin', machine=lambda:'arm64')
        def stop(_):
            raise StopAtPins('fixture stops before package/native/resource access')
        module.Pins = stop
        return module

    def test_used_incomplete_attempt_is_untouched(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            prior = root/'runs/window-2'; prior.mkdir(parents=True, mode=0o700)
            (root/'runs').chmod(0o700)
            sentinel = prior/'input-binding.json'; sentinel.write_bytes(b'prior incomplete attempt\n')
            before = sentinel.stat()
            module = self.temporary_entry(root)
            with self.assertRaises(FileExistsError):
                module.main(['--fixture','window','--attempt','2','--package-sha256','0'*64,'--entrypoint-sha256','1'*64])
            self.assertEqual(sorted(x.name for x in prior.iterdir()), ['input-binding.json'])
            self.assertEqual(sentinel.read_bytes(), b'prior incomplete attempt\n')
            self.assertEqual(sentinel.stat().st_mtime_ns, before.st_mtime_ns)

    def test_fresh_attempt_keeps_first_attempt(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            prior = root/'runs/window-1'; prior.mkdir(parents=True, mode=0o700)
            (root/'runs').chmod(0o700)
            sentinel = prior/'terminal.json'; sentinel.write_bytes(b'original refusal\n')
            module = self.temporary_entry(root)
            with self.assertRaises(StopAtPins):
                module.main(['--fixture','window','--attempt','2','--package-sha256','0'*64,'--entrypoint-sha256','1'*64])
            self.assertEqual(sentinel.read_bytes(), b'original refusal\n')
            result = json.loads((root/'runs/window-2/terminal.json').read_text())
            self.assertFalse(result['nativeLaunchAttempted'])
            self.assertEqual(result['status'], 'failed')

    def test_actual_pins_reject_change_and_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); entry = root/'run_target.py'
            entry.write_bytes(b'fixed entry\n'); entry.chmod(0o600)
            wanted = hashlib.sha256(entry.read_bytes()).hexdigest()
            pins = Pins(); pins.read(entry, 65536, wanted, keep=False); pins.recheck()
            entry.write_bytes(b'changed entry\n')
            with self.assertRaises(ValueError): pins.recheck()
            with self.assertRaises(ValueError): Pins().read(entry, 65536, wanted)
            link = root/'link.py'; link.symlink_to(entry)
            with self.assertRaises(ValueError): Pins().read(link, 65536, wanted)

    def test_entry_inverse_preserves_native_guards_and_supervision(self):
        text = (ROOT/'package/run_target.py').read_text()
        replacements = [
            ('ENTRYPOINT = Path(__file__).absolute()\nROOT = ENTRYPOINT.parent.parent', 'ROOT = Path(__file__).resolve().parent'),
            ("    parser.add_argument('--entrypoint-sha256', required=True)\n", ''),
            ("    parser.add_argument('--attempt', type=int, choices=range(1, 10), default=1)\n", ''),
            ("    require(ENTRYPOINT == ROOT/'operations-retry-20260916/run_target.py', 'Wrong retry entrypoint path')\n", ''),
            ("        candidate = runs/(args.fixture+'-'+str(args.attempt))\n        candidate.mkdir(mode=0o700)  # A used run directory is never overwritten.\n        run = candidate", "        run = runs/(args.fixture+'-1')\n        run.mkdir(mode=0o700)  # A used run directory is never overwritten."),
            ("        entry = pins.read(ENTRYPOINT, 65536, args.entrypoint_sha256, keep=False)\n", ''),
            ("        binding.update(attempt=args.attempt, entrypointSHA256=entry['sha256'])\n", ''),
        ]
        for new, old in replacements:
            self.assertEqual(text.count(new), 1, new)
            text = text.replace(new, old)
        self.assertEqual(text, (ROOT/'originals/package/run_target.py').read_text())

    def test_collector_inverse_preserves_read_only_checks(self):
        text = (ROOT/'collect_remote.py').read_text()
        text = text.replace("assert len(sys.argv)==3 and sys.argv[1] in ('window','session','target') and sys.argv[2] in tuple(str(x) for x in range(1,10))", "assert len(sys.argv)==2 and sys.argv[1] in ('window','session','target')")
        text = text.replace("run=ROOT/'runs'/(sys.argv[1]+'-'+sys.argv[2])", "run=ROOT/'runs'/(sys.argv[1]+'-1')")
        self.assertEqual(text, (ROOT/'originals/collect_remote.py').read_text())

    def test_commands_bind_same_jobs_and_exact_new_entry(self):
        import shlex
        commands = json.loads((ROOT/'ROOT-COMMANDS.json').read_bytes())
        original = json.loads((BASE/'ROOT-COMMANDS.json').read_bytes())
        raw = (ROOT/'package/run_target.py').read_bytes()
        self.assertEqual(commands['entrypointSHA256'], hashlib.sha256(raw).hexdigest())
        for field in ('sshPrefix','knownHosts','packageSHA256','remoteRoot','runTimeoutSeconds'):
            self.assertEqual(commands[field], original[field])
        for fixture, args in commands['runArguments'].items():
            restored = list(args)
            self.assertEqual(restored[-2:], ['--entrypoint-sha256', commands['entrypointSHA256']])
            del restored[-2:]
            entry = commands['remoteRoot']+'/operations-retry-20260916/run_target.py'
            restored[restored.index(entry)] = commands['remoteRoot']+'/run_target.py'
            self.assertEqual(restored, shlex.split(original['runRemote'][fixture][-1]))
        files = json.loads((ROOT/'deployment.json').read_bytes())['files']
        self.assertEqual(files, {'check/run_target.py': dict(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(), mode=0o600)})
        self.assertEqual(shlex.split(commands['copyRemote'][-1])[-1], (ROOT/'install_new_tree.py').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
