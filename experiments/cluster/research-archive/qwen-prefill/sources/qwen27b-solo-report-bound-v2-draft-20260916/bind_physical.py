"""Bind first short-solo root helpers to the successful local package; no copy or remote call."""
from pathlib import Path
import hashlib
import json

BASE = Path(__file__).resolve().parent
OLD = BASE.parent/'qwen27b-matched-short-cohort-draft-20260916/physical-source'
PHYSICAL = BASE/'physical-source'
REMOTE = '/Users/developer/DarkbloomDev/qwen27b-resident-solo-report-fixed-20260916'


def pin(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    run = BASE/'run-source-1'
    job = json.loads((run/'job.json').read_bytes())
    assert job['schema'] == 'private_resident_solo_generation_job_v2' and job['measured_count'] == 1
    assert job['deployment'] == REMOTE+'/native' and job['run_dir'] == REMOTE+'/runs/cohort-1'
    source = BASE/'runtime-bundle-1'
    bundle = json.loads((source/'bundle.json').read_bytes())
    manifest = json.loads((run/'manifest.json').read_bytes())
    deployment = json.loads((OLD/'deployment.json').read_bytes())
    deployment['remoteRoot'] = REMOTE
    files = []
    for root, prefix, rows in [(source,'native',bundle['files']), (run,'supervisor',manifest['files'])]:
        for row in rows:
            files.append(dict(path=prefix+'/'+row['path'], source=str(root/row['path']),
                bytes=row['bytes'], sha256=row['sha256'], mode='0700' if row['path']=='cluster-inference' else '0600'))
        p=root/('bundle.json' if prefix=='native' else 'manifest.json')
        files.append(dict(path=prefix+'/'+p.name, source=str(p), bytes=p.stat().st_size,sha256=pin(p),mode='0600'))
    assert len(files) == 24 and len({x['path'] for x in files}) == 24
    deployment['files'] = files
    # Preserve exact directory modes and resource/model constraints from the reviewed parent.
    for key in list(deployment):
        if key not in ('remoteRoot','files','directories'):
            value = deployment[key]
            if isinstance(value,str):
                deployment[key] = value.replace('qwen27b-resident-solo-short-generation-20260916',
                    'qwen27b-resident-solo-report-fixed-20260916')
    with (PHYSICAL/'deployment.json').open('x') as stream:
        json.dump(deployment,stream,sort_keys=True,indent=2);stream.write('\n')
    path=PHYSICAL/'run_physical.py';raw=path.read_text()
    assert raw.count('__BOUND_JOB_SHA256__') == raw.count('__BOUND_LAUNCHER_SHA256__') == 1
    path.write_text(raw.replace('__BOUND_JOB_SHA256__',pin(run/'job.json')).replace(
        '__BOUND_LAUNCHER_SHA256__',pin(run/'manifest.json')))
    print(json.dumps(dict(files=24,jobSHA256=pin(run/'job.json'),launcherSHA256=pin(run/'manifest.json'),
        deploymentSHA256=pin(PHYSICAL/'deployment.json'),remoteRoot=REMOTE,remoteExecuted=False)))


if __name__ == '__main__':
    main()
