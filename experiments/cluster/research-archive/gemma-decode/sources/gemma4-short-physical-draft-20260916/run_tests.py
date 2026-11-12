"""Root-granted 30-second model-free fixture invocation only."""
import argparse
from pathlib import Path
import sys
from check_process import run_owned

def main():
    p=argparse.ArgumentParser(allow_abbrev=False);p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    if not a.output.is_absolute() or a.output.parent.resolve()!=a.output.parent:raise ValueError('Canonical fresh output required')
    a.output.mkdir(mode=0o700)
    run_owned([sys.executable,'-B',str(Path(__file__).resolve().parent/'Tests/test_supervision.py')],a.output,'fixtures',30)
if __name__=='__main__':main()
