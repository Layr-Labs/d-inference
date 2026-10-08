"""One root-granted, bounded source-overlay child; preserves failure output."""
import os,sys
from context import BASE
from check_process import run_owned

if __name__=='__main__':
    os.umask(0o077)
    output=BASE/'preparation-control-1';output.mkdir(mode=0o700)
    run_owned([sys.executable,'-B',str(BASE/'prepare.py'),'--apply'],output,'prepare',120)
