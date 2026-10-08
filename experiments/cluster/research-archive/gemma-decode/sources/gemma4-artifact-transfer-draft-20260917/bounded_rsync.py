"""Same-PID sender with a one-MiB per-output-file kernel bound."""
import os
import resource
import sys
from source_guard import check_sources

def main():
    check_sources()
    if len(sys.argv)<3 or sys.argv[1]!='/usr/bin/rsync':raise ValueError('Exact rsync executable')
    resource.setrlimit(resource.RLIMIT_FSIZE,(1048576,1048576))
    os.execv(sys.argv[1],sys.argv[1:])
if __name__=='__main__':main()
