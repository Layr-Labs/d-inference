"""Only fake CPU tests and Python3.9 parsing; no real process/socket entry."""
import ast
from pathlib import Path
import unittest
from unittest.mock import patch


def main():
    folder=Path(__file__).parent
    files=sorted(folder.glob('*.py'))
    for path in files:ast.parse(path.read_text(),filename=str(path),feature_version=(3,9))
    with patch('subprocess.Popen',side_effect=AssertionError('No processes in CPU checks')), \
         patch('subprocess.run',side_effect=AssertionError('No processes in CPU checks')), \
         patch('socket.socket',side_effect=AssertionError('No sockets in CPU checks')):
        suite=unittest.defaultTestLoader.discover(str(folder),pattern='test_*.py')
        result=unittest.TextTestRunner(verbosity=2).run(suite)
    print('Python3.9 syntax:',len(files),'files')
    return 0 if result.wasSuccessful() else 1


if __name__=='__main__':raise SystemExit(main())
