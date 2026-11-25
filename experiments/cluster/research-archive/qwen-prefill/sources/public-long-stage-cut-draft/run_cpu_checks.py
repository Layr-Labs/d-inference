"""Run proposed and retained public fake tests without process/socket entry points."""
import argparse
import ast
from contextlib import ExitStack
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, required=True)
    args = parser.parse_args()
    original = args.repository.resolve() / 'experiments/cluster'
    proposed = HERE / 'proposed/experiments/cluster'
    sys.path[:0] = [str(proposed), str(original)]
    with ExitStack() as stack:
        for name in ('subprocess.Popen', 'subprocess.run', 'socket.socket', 'os.system', 'os.fork'):
            stack.enter_context(patch(name, side_effect=AssertionError('Only fake process/socket services are allowed')))
        import runtime.stage_checks
        runtime.stage_checks.__path__.insert(0, str(proposed / 'runtime/stage_checks'))
        names = {path.stem for path in original.glob('test_stage_checks*.py')}
        names.update(path.stem for path in proposed.glob('test_stage_checks*.py'))
        for path in proposed.rglob('*.py'):
            ast.parse(path.read_text(), filename=str(path), feature_version=(3, 9))
        suite = unittest.defaultTestLoader.loadTestsFromNames(sorted(names))
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__': raise SystemExit(main())
