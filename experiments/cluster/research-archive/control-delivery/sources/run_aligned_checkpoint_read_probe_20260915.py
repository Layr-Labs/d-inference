import datetime
import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent
probe = root / 'aligned_checkpoint_read_probe_20260915.py'
rows = [[cell.strip().strip('`') for cell in line.strip().strip('|').split('|')]
        for line in (root.parent / 'machines/CREDENTIALS.private.md').read_text().splitlines()
        if line.strip().startswith('|')]
password = rows[2][[cell.lower() for cell in rows[0]].index('password')]
purge = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
                        'darkbloom-24', "/usr/bin/sudo -k -S -p '' /usr/sbin/purge"],
                       input=password + '\n', capture_output=True, text=True, timeout=30)
record = dict(atUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              sourceSHA256=hashlib.sha256(probe.read_bytes()).hexdigest(),
              purge=dict(exitCode=purge.returncode, stdout=purge.stdout.replace(password, '[REDACTED]'),
                         stderr=purge.stderr.replace(password, '[REDACTED]')))
if purge.returncode == 0:
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
                             'darkbloom-24', '/usr/bin/python3 -'], input=probe.read_text(),
                            capture_output=True, text=True, timeout=110)
    record.update(exitCode=result.returncode, stderr=result.stderr.replace(password, '[REDACTED]'),
                  records=[json.loads(line) for line in result.stdout.splitlines()])
output = root / 'peer24-aligned-checkpoint-read-observation-20260915.json'
output.write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(dict(receipt=str(output), exitCode=record.get('exitCode'),
    purgeExitCode=purge.returncode, stderr=record.get('stderr'),
    passes=[dict(name=item['name'], seconds=item['seconds'],
                 deltaBytes={key:item['samples'][-1]['values'][key]-item['samples'][0]['values'][key]
                             for key in item['samples'][0]['values']})
            for item in record.get('records', []) if 'samples' in item])), flush=True)
assert purge.returncode == 0 and record['exitCode'] == 0
