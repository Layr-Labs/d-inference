"""Reclaim filesystem cache only when both native device owners are absent."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys
sys.path.insert(0, "/Users/developer/DarkbloomDev/cluster-research/gemma4-mtp-remote-qualification-physical-v3-20260920")
from deploy import REMOTE
from parent_settings import SSH
from run_case import QUIESCENT


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists() and args.output.parent.is_dir()
    hosts = ['darkbloom-24']
    records = []
    for host in hosts:
        observed = subprocess.run(SSH + [host, shlex.join(['/usr/bin/python3', '-B', '-c', QUIESCENT])],
                                  capture_output=True, timeout=10)
        assert observed.returncode == 0 and not observed.stderr, 'Native device is not quiescent'
        records.append(dict(host=host, quiescence=json.loads(observed.stdout)))
    private = Path('/Users/developer/DarkbloomDev/machines/CREDENTIALS.private.md')
    assert private.is_file() and not private.is_symlink() and private.stat().st_mode & 0o077 == 0
    rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
            for line in private.read_text().splitlines() if line.startswith('|')]
    password = rows[2][[cell.lower() for cell in rows[0]].index('password')]
    sample = ('import sys,json;sys.path.insert(0,' + repr(REMOTE) + ');'
              'from reference_resources import sample_local,validate_local;'
              'value=sample_local();validate_local(value);print(json.dumps(value))')
    for record in records:
        host = record['host']
        result = subprocess.run(SSH + [host, "/usr/bin/sudo -k -S -p '' /usr/sbin/purge"],
                                input=(password+'\n').encode(), capture_output=True, timeout=30)
        record['purge'] = dict(exitCode=result.returncode, stdoutBytes=len(result.stdout), stderrBytes=len(result.stderr))
        assert result.returncode == 0, 'Authorized cache preparation failed; no credential output retained'
        observed = subprocess.run(SSH + [host, shlex.join(['/usr/bin/python3', '-B', '-c', sample])],
                                  capture_output=True, timeout=10)
        assert observed.returncode == 0 and not observed.stderr, 'Fresh resource observation failed'
        record['resources'] = json.loads(observed.stdout)
        print(json.dumps(dict(host=host, actualFreeBytes=record['resources']['actualFreeBytes'],
                              pressureLevel=record['resources']['pressureLevel'],
                              acPower=record['resources']['acPower'], reportedSwapBytes=record['resources']['reportedSwapBytes'])), flush=True)
    with args.output.open('x') as stream:
        json.dump(dict(schema='gemma4_quiescent_cache_preparation_v1', records=records), stream, indent=2)


if __name__ == '__main__':
    main()
