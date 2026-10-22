"""Root-granted bounded preparation parent; no compiler launch."""
import json,os,sys
from context import BASE
from check_process import run_owned

def main():
    out=BASE/'prepare-control-1';out.mkdir(mode=0o700,exist_ok=False)
    value=run_owned([sys.executable,'-B',str(BASE/'prepare.py'),'--apply'],out,'preparation',120)
    print(json.dumps(value,sort_keys=True))
if __name__=='__main__':os.umask(0o077);main()
