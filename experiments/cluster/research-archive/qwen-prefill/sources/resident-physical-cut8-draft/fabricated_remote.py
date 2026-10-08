"""CPU-only supervisor test entry; never an accepted real launcher operation."""
import json
from pathlib import Path
import sys
from physical_common import Pins
from remote_resident import serve
from worker_contract import WorkerSpec

jobs=json.loads(Path(sys.argv[1]).read_bytes());rank=int(sys.argv[2]);job=jobs[rank]
scenario='success' if sys.argv[3]=='hash_fail' else sys.argv[3]
spec=WorkerSpec((sys.executable,'-B',str(Path(__file__).parent/'fabricated_rank.py'),sys.argv[1],str(rank),scenario),
    dict(PATH='/usr/bin:/bin',PYTHONDONTWRITEBYTECODE='1'),'rank',rank)
if sys.argv[3]=='hash_fail':
    from unittest.mock import patch
    with patch('remote_resident.PipeWorkers.retained_streams',side_effect=OSError('fabricated stream hash error')):
        code=serve(job,spec,job['peer']['run_dir'],lambda phase:None,Pins(),timeout=10)
else:code=serve(job,spec,job['peer']['run_dir'],lambda phase:None,Pins(),timeout=10)
raise SystemExit(code)
