"""Test an out-of-tree source overlay without processes, sockets or native work."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cluster',type=Path,required=True)
    parser.add_argument('--receipt',type=Path,required=True)
    args=parser.parse_args();draft=Path(__file__).resolve().parent;cluster=args.cluster.resolve(strict=True)
    if args.receipt.exists():raise ValueError('CPU receipt must be a new file')
    sources=list(draft.rglob('*.py'))
    for source in sources:ast.parse(source.read_text(),filename=str(source))
    started=time.monotonic()
    with tempfile.TemporaryDirectory(prefix='stage-prefill-cpu-') as temporary:
        assembled=Path(temporary)/'cluster';target=assembled/'runtime/stage_checks';target.mkdir(parents=True)
        shutil.copyfile(cluster/'runtime/__init__.py',assembled/'runtime/__init__.py')
        for folder in (cluster/'runtime/stage_checks',draft/'runtime/stage_checks'):
            for path in folder.glob('*'):
                if path.is_file():shutil.copyfile(path,target/path.name)
        shutil.copyfile(draft/'run_stage_checks.py',assembled/'run_stage_checks.py')
        for name in ('test_stage_checks.py','test_stage_checks_supervision.py'):
            shutil.copyfile(cluster/name,assembled/name)
        for source in (draft/'tests').glob('*.py'):shutil.copyfile(source,assembled/source.name)
        sys.path.insert(0,str(assembled))
        with patch('subprocess.Popen',side_effect=AssertionError('Process creation forbidden')), \
             patch('subprocess.run',side_effect=AssertionError('System/native calls forbidden')), \
             patch('socket.socket',side_effect=AssertionError('Socket creation forbidden')):
            suite=unittest.defaultTestLoader.discover(str(assembled),pattern='test_stage_checks*.py')
            result=unittest.TextTestRunner(verbosity=2).run(suite)
    receipt=dict(kind='public_prefill_ranks_draft_cpu_checks',schema_version=1,passed=result.wasSuccessful(),
        tests_run=result.testsRun,failures=len(result.failures),errors=len(result.errors),elapsed_seconds=time.monotonic()-started,
        process_and_socket_creation_guarded=True,native_execution_attempted=False,model_payload_read=False,
        source_files=[dict(path=p.relative_to(draft).as_posix(),sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in sorted(sources)])
    args.receipt.write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n')
    return 0 if result.wasSuccessful() else 1


if __name__=='__main__':sys.exit(main())
