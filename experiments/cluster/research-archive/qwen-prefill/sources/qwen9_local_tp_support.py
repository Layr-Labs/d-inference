"""CPU guards and owned-process supervision for the external real9B diagnostic."""
import importlib.util
import math
import os
from pathlib import Path
import re
import resource
import signal
import struct
import subprocess
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('qwen9_previous_driver', HERE / 'validate-qwen9-output-boundaries.py')
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)
require, sha, read_json, write_json, now = previous.require, previous.sha, previous.read_json, previous.write_json, previous.now
PREVIOUS_DRIVER_SHA = '80bba4f397a236e347c68c250d7a2625955189dedd259f21a926a0656a0b5f0a'
GIB = 1024 ** 3
# Conservative reference, not a predicted TP allocation: maximum measured solo
# peak for the same registered artifact/input, both output projections widened.
PRIOR_SOLO_PEAK = 5609991782
HEADROOM_BYTES = GIB
SOURCE_BYTES = 5038041600
LOADED_BYTES = {'solo': SOURCE_BYTES, 'ffn': 3679087104, 'full': 3091423488}
LARGEST_SELECTED_HOST_BYTES = 508559360


def preflight(partition, output):
    world_size = 1 if partition == "solo" else 2
    physical = int(subprocess.check_output(['/usr/sbin/sysctl','-n','hw.memsize'],text=True,timeout=5))
    raw = subprocess.check_output(['/usr/bin/vm_stat'],text=True,timeout=5)
    page_size = int(re.search(r'page size of (\d+) bytes',raw).group(1))
    pages = {}
    for line in raw.splitlines()[1:]:
        match = re.fullmatch(r'(.+?):\s+(\d+)\.',line)
        if match: pages[match.group(1)] = int(match.group(2))
    # Inactive pages are an estimate of reclaimable capacity, not guaranteed
    # immediately free bytes. Avoid double-counting overlapping purgeable/file pages.
    available = sum(pages[k] for k in ('Pages free','Pages inactive','Pages speculative')) * page_size
    required = world_size * (LOADED_BYTES[partition] + max(0, PRIOR_SOLO_PEAK-SOURCE_BYTES)
                             + LARGEST_SELECTED_HOST_BYTES) + HEADROOM_BYTES
    pressure_query = subprocess.check_output(['/usr/bin/memory_pressure','-Q'],text=True,timeout=5)
    pressure_level = int(subprocess.check_output(['/usr/sbin/sysctl','-n','kern.memorystatus_vm_pressure_level'],text=True,timeout=5))
    swap_query = subprocess.check_output(['/usr/sbin/sysctl','vm.swapusage'],text=True,timeout=5).strip()
    swap_used = int(float(re.search(r'used = ([0-9.]+)M',swap_query).group(1))*1024**2)
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    descriptors = 0
    fd_path = Path('/dev/fd')
    if fd_path.exists(): descriptors = len(list(fd_path.iterdir()))
    disk = __import__('shutil').disk_usage(output)
    result = dict(at=now(), physical_bytes=physical, page_size_bytes=page_size,
        vm_stat=raw, swap_usage=swap_query,swap_used_bytes=swap_used,memory_pressure_query=pressure_query,
        memory_pressure_level=pressure_level,severe_pressure=pressure_level>=4,
        estimated_reclaimable_bytes=available, estimated_reclaimable_formula='(free + inactive + speculative) * page_size; overlapping categories excluded',
        required_headroom_bytes=required, headroom_policy='world_size * (selected stored bytes + max(0, prior wider solo peak - canonical source bytes) + largest selected host tensor) + 1 GiB',
        partition=partition,canonical_source_bytes=SOURCE_BYTES,per_rank_selected_stored_bytes=LOADED_BYTES[partition],
        per_rank_largest_selected_host_bytes=LARGEST_SELECTED_HOST_BYTES,estimate_is_not_safety_guarantee=True,
        prior_solo_peak_bytes=PRIOR_SOLO_PEAK, prior_peak_is_not_a_TP_prediction=True,
        world_size=world_size, nofile_soft=soft,nofile_hard=hard,driver_open_descriptors=descriptors,
        disk_free_bytes=disk.free,required_disk_free_bytes=4*GIB,
        memory_passed=available>=required,descriptors_passed=soft>=256 and descriptors+128<soft,
        disk_passed=disk.free>=4*GIB)
    result['passed'] = result['memory_passed'] and result['descriptors_passed'] and result['disk_passed'] and not result['severe_pressure']
    return result


def process_table():
    raw = subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,pgid=,rss=,lstart=,command='],text=True,timeout=5)
    result = {}
    for line in raw.splitlines():
        fields = line.split(None,9)
        if len(fields) == 10:
            pid, parent, group, rss_kib = map(int,fields[:4])
            result[pid] = dict(pid=pid, parent=parent, group=group,rss_bytes=rss_kib*1024,
                               started=' '.join(fields[4:9]), command=fields[9])
    return result


def expand_owned(table, root_pid, owned):
    root = table.get(root_pid)
    if root is not None and root_pid not in owned: owned[root_pid] = root
    changed = True
    while changed:
        changed = False
        parents = {pid for pid, record in owned.items() if pid in table and
                   table[pid]['started']==record['started']}
        for pid, record in table.items():
            if record['parent'] in parents and pid not in owned:
                owned[pid] = record; changed = True
    return {pid:record for pid,record in owned.items() if pid in table and
            table[pid]['started']==record['started']}


def retire(child, run_directory, owned):
    # Give each supervisor its cancellation file first. Its finally kills and
    # waits for the native process group even if the native leader already exited.
    for rank in run_directory.glob('rank-*'):
        if rank.is_dir(): (rank/'cancel').touch()
    table = process_table(); live = expand_owned(table,child.pid,owned)
    for pid, record in live.items():
        if 'rank_worker.py' in record['command']:
            try: os.kill(pid,signal.SIGTERM)
            except ProcessLookupError: pass
    deadline = time.monotonic()+4
    while time.monotonic()<deadline:
        child.poll()
        live=expand_owned(process_table(),child.pid,owned)
        if not live: break
        time.sleep(.05)
    # No unowned process is signalled. Recheck PID birth before every fallback.
    # A group is signalled only when an observed live owned member still belongs
    # to it. This handles an exited native leader with an owned surviving child.
    table=process_table();live=expand_owned(table,child.pid,owned)
    for group in {record['group'] for record in live.values()}:
        if group==os.getpgrp(): continue
        members=[record for record in table.values() if record['group']==group]
        require(all(r['pid'] in owned and owned[r['pid']]['started']==r['started'] for r in members),
                'Refusing to signal a process group containing an unowned member')
        try: os.killpg(group,signal.SIGKILL)
        except ProcessLookupError: pass
    try: child.wait(timeout=5)
    except subprocess.TimeoutExpired: raise RuntimeError('Owned launcher did not exit after bounded cleanup')
    remaining=expand_owned(process_table(),child.pid,owned)
    require(not remaining,'Owned process survived cleanup: '+str(list(remaining)))
    return dict(owned_processes=list(owned.values()),all_observed_owned_processes_exited=True,
                launcher_reaped=True,cancel_files_requested=True)


def bounded_launch(command, run_directory, log_directory, env, entry, save, partition):
    log_directory.mkdir(mode=0o700)
    entry.update(command=command,started_at=now(),outer_timeout_seconds=195,owned_processes=[])
    started=time.monotonic();owned={};child=None;error=None;next_memory=started
    initial_swap=entry['preflight']['swap_used_bytes']
    entry.update(memory_samples=[],peak_observed_owned_rss_bytes=0)
    with (log_directory/'stdout.txt').open('wb') as stdout,(log_directory/'stderr.txt').open('wb') as stderr:
        try:
            child=subprocess.Popen(command,cwd=log_directory,env=env,stdin=subprocess.DEVNULL,
                stdout=stdout,stderr=stderr,start_new_session=True)
            entry['launcher_pid']=child.pid;save()
            deadline=started+195
            while True:
                table=process_table();live=expand_owned(table,child.pid,owned)
                rss=sum(table[pid]['rss_bytes'] for pid in live)
                entry['peak_observed_owned_rss_bytes']=max(entry['peak_observed_owned_rss_bytes'],rss)
                if time.monotonic()>=next_memory:
                    sample=preflight(partition,run_directory.parent)
                    sample['owned_process_rss_bytes']=rss
                    entry['memory_samples'].append(sample);save()
                    require(not sample['severe_pressure'],'Critical system memory pressure: retiring cohort')
                    require(sample['swap_used_bytes']-initial_swap<=GIB,'More than 1 GiB new swap: retiring cohort')
                    next_memory=time.monotonic()+1
                code=child.poll()
                if code is not None: break
                require(time.monotonic()<deadline,'Outer launcher deadline expired')
                time.sleep(.1)
            child.wait(timeout=1)
            entry['exit_code']=code
            live=expand_owned(process_table(),child.pid,owned)
            if live: entry['cleanup']=retire(child,run_directory,owned)
            else: entry['cleanup']=dict(all_observed_owned_processes_exited=True,launcher_reaped=True,cancel_files_requested=False)
            require(code==0,'Inference launcher failed with exit '+str(code))
        except BaseException as caught:
            error=caught
            if child is not None:
                try: entry['cleanup']=retire(child,run_directory,owned)
                except BaseException as cleanup_error: entry['cleanup_error']=repr(cleanup_error)
            raise
        finally:
            entry.update(owned_processes=list(owned.values()),finished_at=now(),wall_seconds=time.monotonic()-started,
                stdout_sha256=sha(log_directory/'stdout.txt'),stderr_sha256=sha(log_directory/'stderr.txt'))
            if error: entry['failure']=f'{type(error).__name__}: {error}'
            save()


def f32_rows(rows,vocabulary):
    require(isinstance(rows,list) and len(rows)==4,'Expected four logit rows')
    result=[]
    for row in rows:
        require(isinstance(row,list) and len(row)==vocabulary,'Wrong vocabulary width')
        require(all(type(x) in (float,int) and math.isfinite(x) for x in row),'Nonfinite/bool logit')
        values=[struct.unpack('<f',struct.pack('<f',x))[0] for x in row]
        require(all(math.isfinite(x) for x in values),'Nonfinite reconstructed Float32')
        result.append(values)
    return result


def compare(left,right,vocabulary):
    a,b=f32_rows(left,vocabulary),f32_rows(right,vocabulary); rows=[]
    for index,(x,y) in enumerate(zip(a,b,strict=True)):
        diff=[v-u for u,v in zip(x,y,strict=True)]
        maximum=max(map(abs,diff)); rms=math.sqrt(math.fsum(v*v for v in diff)/max(math.fsum(u*u for u in x),1e-30))
        ax,bx=x.index(max(x)),y.index(max(y))
        rows.append(dict(row=index,compared_values=vocabulary,differing_values=sum(u!=v for u,v in zip(x,y)),
            exact=x==y,max_absolute=maximum,relative_rms=rms,reference_argmax=ax,candidate_argmax=bx,
            argmax_equal=ax==bx,passed=maximum<.001 and rms<.0001 and ax==bx))
    return dict(exact=a==b,json_values_exact=left==right,passed=all(r['passed'] for r in rows),
                arithmetic='IEEE Float32 reconstructed from native JSON values',rows=rows)
