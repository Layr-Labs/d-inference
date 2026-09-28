"""Initial v3 screen, before model hashing can change the file-cache mix."""
from datetime import datetime,timezone
import re
import subprocess
import time
from .common import require


def initial_free_screen(read=None):
    if read is None:
        read=lambda:subprocess.run(['/usr/bin/vm_stat'],check=True,capture_output=True,text=True,timeout=2).stdout
    raw=read();require(type(raw)is str and len(raw)<=16384,'Invalid bounded vm_stat output')
    page=re.search(r'page size of (\d+) bytes',raw)
    require(page is not None and int(page[1])>0,'Invalid page size')
    pages={}
    for line in raw.splitlines()[1:]:
        match=re.fullmatch(r'(.+?):\s+(\d+)\.',line)
        if match:
            require(match[1] not in pages,'Duplicate vm_stat page counter');pages[match[1]]=int(match[2])
    free=pages['Pages free']*int(page[1])
    reclaimable=sum(pages[key] for key in ('Pages free','Pages inactive','Pages speculative'))*int(page[1])
    return dict(phase='before_source_bundle_snapshot_and_artifact_hashing',timestamp_utc=datetime.now(timezone.utc).isoformat(),
        monotonic_seconds=time.monotonic(),vm_stat=raw,actual_free_bytes=free,required_actual_free_bytes=6*1024**3,
        estimated_reclaimable_bytes=reclaimable,passed=free>=6*1024**3,
        actual_free_formula='Pages free * page_size; excludes inactive/speculative/reclaimable pages',
        guarantees_six_gib_free_at_native_launch=False)
