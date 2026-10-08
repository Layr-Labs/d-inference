"""Root-only bounded retrieval of the two exact completed 27B sidecars."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from prepare_packet import bootstrap, digest, PARENT, PARENT_SHA, COMPARATOR_SHA

HERE = Path(__file__).resolve().parent
MAX_RESPONSE = 24*1024**2


def publish(path, raw):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())


def decode_response(raw):
    from audit_common import parse, fields, exact, integer, sha
    from read_sidecar_remote import SIDECAR
    if not 0 < len(raw) <= MAX_RESPONSE:
        raise ValueError('Sidecar transport response outside bound')
    packet = fields(parse(raw), 'schema path bytes sha256 identity data active journalBytes journalSHA256 journalIdentity', 'retrieval')
    exact(packet['schema'], 'qwen27b_sidecar_collection_v1', 'retrieval schema')
    exact(packet['path'], SIDECAR, 'exact sidecar path')
    integer(packet['bytes'], 1, 16*1024**2)
    if type(packet['data']) is not str or len(packet['data']) > 4*((16*1024**2+2)//3):
        raise ValueError('Base64 sidecar outside bound')
    data = base64.b64decode(packet['data'], validate=True)
    exact(len(data), packet['bytes'], 'sidecar size')
    exact(hashlib.sha256(data).hexdigest(), sha(packet['sha256']), 'sidecar hash')
    integer(packet['journalBytes'], 0, 65536)
    sha(packet['journalSHA256'])
    if packet['journalBytes'] == 0:
        exact(packet['journalSHA256'], hashlib.sha256(b'').hexdigest(), 'empty journal hash')
    for name in ('identity', 'journalIdentity'):
        if type(packet[name]) is not list or len(packet[name]) != 6:
            raise ValueError('File identity missing')
        for item in packet[name]: integer(item)
    if type(packet['active']) is not list or any(type(item) is not str for item in packet['active']):
        raise ValueError('Process observation missing')
    return data, {key: value for key, value in packet.items() if key != 'data'}


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument('--output-directory', required=True)
    args = parser.parse_args()
    bootstrap()
    sys.path.insert(0, str(PARENT))
    from parent_settings import SSH
    known_hosts = next(value.split('=', 1)[1] for value in SSH if value.startswith('UserKnownHostsFile='))
    if digest(Path(known_hosts)) != '89a73d7ca9fe16a0c1aeb0fa6cfa640ff37a02d4a2d21114e7ad5fca089443ed':
        raise ValueError('Development SSH trust changed')
    directory = Path(args.output_directory).absolute()
    directory.mkdir(mode=0o700, exist_ok=False)
    source = (HERE / 'read_sidecar_remote.py').read_bytes()
    records = []
    for rank, host in enumerate(('darkbloom-24', 'darkbloom-48')):
        record = {'rank': rank, 'host': host, 'status': 'failed'}
        interrupted = False
        try:
            result = subprocess.run(SSH + [host, '/usr/bin/python3 -B -'], input=source,
                                    capture_output=True, timeout=30)
            publish(directory / ('rank' + str(rank) + '.transport.stdout'), result.stdout)
            publish(directory / ('rank' + str(rank) + '.transport.stderr'), result.stderr)
            record['sshExitCode'] = result.returncode
            if result.returncode != 0 or result.stderr:
                raise ValueError('Sidecar SSH failed or emitted stderr')
            data, observed = decode_response(result.stdout)
            filename = directory / ('rank' + str(rank) + '-evidence.json')
            publish(filename, data)
            record.update(observed=observed, path=str(filename), sha256=observed['sha256'], bytes=len(data))
            if observed['active'] or observed['journalBytes'] != 0:
                raise ValueError('Fresh process/journal observation refused')
            record['status'] = 'collected'
        except subprocess.TimeoutExpired as error:
            publish(directory / ('rank' + str(rank) + '.transport.stdout'), error.stdout or b'')
            publish(directory / ('rank' + str(rank) + '.transport.stderr'), error.stderr or b'')
            record['error'] = 'Sidecar SSH exceeded 30-second bound'
        except KeyboardInterrupt:
            record['error'] = 'KeyboardInterrupt during sidecar collection'
            interrupted = True
        except Exception as error:
            record['error'] = type(error).__name__ + ': ' + str(error)
        records.append(record)
        if interrupted:
            break
    receipt = {'schema': 'qwen27b_sidecars_collected_v1', 'ranks': records,
        'status': 'collected' if len(records) == 2 and all(row['status'] == 'collected' for row in records) else 'failed',
        'parentManifestSHA256': PARENT_SHA, 'comparatorManifestSHA256': COMPARATOR_SHA,
        'readerSHA256': hashlib.sha256(source).hexdigest(), 'numericalComparisonPerformed': False,
        'nativeReleaseAcknowledgmentsVerified': False, 'rootPhysicalEvidenceStillRequired': True}
    publish(directory / 'collection.json', (json.dumps(receipt, indent=2, sort_keys=True) + '\n').encode())
    print(json.dumps({'status': receipt['status'], 'collectionSHA256': digest(directory / 'collection.json')}))
    return 0 if receipt['status'] == 'collected' else 1


if __name__ == '__main__':
    raise SystemExit(main())
