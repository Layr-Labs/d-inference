#!/usr/bin/env python3
"""CPU-only overlay runner; does not edit the supplied repository."""
import argparse
import ast
import json
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cluster-root', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args(); source = args.cluster_root.resolve(strict=True)
    draft = Path(__file__).parent
    if args.receipt.exists(): raise ValueError('Preserve existing test receipt')
    for path in draft.glob('*.py'): ast.parse(path.read_text(), feature_version=(3,9))
    with tempfile.TemporaryDirectory() as temporary:
        target = Path(temporary) / 'repo/experiments/cluster'; target.mkdir(parents=True)
        for path in list(source.glob('*.py')) + list((source / 'runtime').rglob('*.py')):
            relative = path.relative_to(source); destination = target / relative
            destination.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(path, destination)
        for path in draft.glob('*.py'):
            if path.name == 'run_draft_tests.py': continue
            relative = path.name if path.name.startswith(('test_', 'stage_long_')) else 'runtime/stage_checks/' + path.name
            shutil.copyfile(path, target / relative)
        sys.path.insert(0, str(target))
        suite = unittest.defaultTestLoader.discover(str(target), pattern='test_stage_checks*.py')
        began = time.monotonic()
        with patch('subprocess.Popen', side_effect=AssertionError('No process calls in CPU suite')), \
             patch('subprocess.run', side_effect=AssertionError('No process calls in CPU suite')), \
             patch('socket.socket', side_effect=AssertionError('No sockets in CPU suite')):
            result = unittest.TextTestRunner(verbosity=2).run(suite)
        receipt = dict(kind='public_long_prefill_draft_cpu_tests', passed=result.wasSuccessful(), tests=result.testsRun,
            failures=len(result.failures), errors=len(result.errors), elapsedSeconds=time.monotonic()-began,
            python39SyntaxPassed=True, realProcessAndSocketEntryPointsBlocked=True,
            repositoryMutated=False, nativeExecuted=False, candidateOutputRead=False)
        with args.receipt.open('x') as stream: json.dump(receipt, stream, indent=2, sort_keys=True); stream.write('\n')
        return 0 if result.wasSuccessful() else 1


if __name__ == '__main__': sys.exit(main())
