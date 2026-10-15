"""Read-only owned-generation observation; no signal or journal mutation."""
import json,shlex,subprocess
from parent_settings import SSH
REMOTE='/Users/developer/DarkbloomDev/qwen-mtp-accepted-qualification-20260920/depth1'
def postflight(host, remote_run=None, timeout=15):
    if remote_run is not None or not 0<timeout<=15: raise ValueError('Closed postflight scope')
    command=['/usr/bin/python3','-B',REMOTE+'/collect_owner.py','observe']
    result=subprocess.run(SSH+[host,shlex.join(command)],capture_output=True,timeout=timeout,check=True)
    if result.stderr or len(result.stdout)>65536: raise ValueError('Bounded postflight output differs')
    return json.loads(result.stdout)
