"""Read-only remote check of installed source, existing native bundle and resources."""
import argparse
import json
import os
from pathlib import Path
import signal
import stat
import sys
import time

ROOT = Path('/Users/developer/DarkbloomDev/qwen9b-protected-reference-20260917')
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'package'))
from binding_common import parse, require, same
from reference_inputs import Pins, verify_launcher, verify_inputs, validate_job
from reference_settings import require_short
from reference_resources import sample_local, validate_local
from mtp_journal import device_directory, observe as journal, require_empty
from target_processes import observe as processes


def main():
    signal.alarm(45)
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--job-sha256', required=True)
    parser.add_argument('--launcher-sha256', required=True)
    args = parser.parse_args()
    require(ROOT.is_dir() and ROOT.resolve() == ROOT, 'Canonical installed namespace required')
    require((ROOT / 'runs').is_dir() and not list((ROOT / 'runs').iterdir()), 'No previous reference run permitted')
    before = journal(device_directory()); require_empty(before)
    live = processes(time.monotonic() + 4); require(not live['prohibited'], 'Native/owner already live')
    initial = sample_local(); validate_local(initial)
    pins = Pins()
    verify_launcher(ROOT / 'package', args.launcher_sha256, pins)
    job = validate_job(parse(pins.read(ROOT / 'inputs/job.json', 16384, args.job_sha256)['raw']))
    require_short(job)
    _, tokens = verify_inputs(job, pins)
    model = Path(job['model_dir'])
    manifest = parse(pins.read(model / 'manifest.json', 4*1024**2)['raw'])
    require(manifest['file_count'] == len(manifest['files']) == 12, 'Exact registered9B artifact file count')
    availability = []
    for row in manifest['files']:
        relative = Path(row['path'])
        require(not relative.is_absolute() and '..' not in relative.parts and str(relative) == row['path'], 'Artifact member path')
        path = model / relative
        require(path.parent.resolve() == path.parent, 'Artifact parent link')
        value = path.lstat()
        require(stat.S_ISREG(value.st_mode) and value.st_uid == os.geteuid() and value.st_mode & 0o022 == 0
                and value.st_size == row['size_bytes'], 'Registered payload availability/size differs')
        availability.append(dict(path=row['path'], bytes=value.st_size, device=value.st_dev, inode=value.st_ino))
    pins.recheck()
    after = journal(device_directory()); require_empty(after, before)
    final_live = processes(time.monotonic() + 4); require(not final_live['prohibited'], 'Native/owner appeared during preflight')
    final = sample_local(); validate_local(final)
    print(json.dumps(dict(schema='qwen9b_reference_installed_preflight_v1', jobSHA256=args.job_sha256,
        launcherSHA256=args.launcher_sha256, promptSHA256=job['prompt_sha256'], promptCount=len(tokens),
        nativeSHA256=job['native_sha256'], bundleSHA256=job['bundle_sha256'],
        journalBefore=before, journalAfter=after, processesBefore=live, processesAfter=final_live,
        initialResources=initial, finalResources=final, modelFileAvailability=availability,
        modelPayloadHashed=False, nativeBundleHashed=True, nativeLaunched=False,
        leaseAcquired=False, journalMutated=False, protocolReleaseACK=False), sort_keys=True))


if __name__ == '__main__':
    main()
