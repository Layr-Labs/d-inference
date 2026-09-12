"""Verify the additive raw capsule; optionally reproduce its CPU-only analysis."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import sys
import tarfile
import tempfile


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify(directory, reproduce=False):
    receipt = json.loads((directory / 'raw-evidence-manifest.json').read_text())
    archive_path = directory / receipt['archive']['filename']
    require(sha(archive_path.read_bytes()) == receipt['archive']['sha256'], 'archive hash differs')
    require(archive_path.stat().st_size == receipt['archive']['bytes'], 'archive length differs')
    payloads = {}
    with tarfile.open(archive_path, 'r:gz') as archive:
        members = archive.getmembers()
        require(len(members) == receipt['archive']['regular_file_count'], 'entry count differs')
        for member in members:
            name = PurePosixPath(member.name)
            require(member.isfile() and not name.is_absolute() and '..' not in name.parts,
                    'archive contains a non-file or unsafe path')
            require(member.name not in payloads and member.name in receipt['entries'], 'unexpected entry')
            data = archive.extractfile(member).read()
            expected = receipt['entries'][member.name]
            require(len(data) == expected['bytes'] and sha(data) == expected['sha256'],
                    'entry does not match its receipt: ' + member.name)
            payloads[member.name] = data
    require(set(payloads) == set(receipt['entries']), 'incomplete capsule')
    source_data = payloads['execution-results-manifest.json']
    require(sha(source_data) == receipt['source_manifest']['sha256'], 'source manifest hash differs')
    require(source_data == (directory / 'execution-results-manifest.json').read_bytes(),
            'capsule source manifest differs from the original banked manifest')
    source = json.loads(source_data)
    require(len(source['files']) == receipt['source_manifest']['payload_count'] == 137,
            'source payload count differs')
    require(receipt['excluded_source_entries'] == [], 'unexpected source exclusions')
    require(set(payloads) == set(source['files']) | {'execution-results-manifest.json'},
            'capsule adds or omits a source entry')
    for name, expected in source['files'].items():
        require(len(payloads[name]) == expected['bytes'] and sha(payloads[name]) == expected['sha256'],
                'payload differs from frozen execution manifest: ' + name)
    result = {'verified_source_payloads': 137, 'archive_sha256': receipt['archive']['sha256'],
              'excluded_source_entries': [], 'reproduced_analysis': False}
    if reproduce:
        with tempfile.TemporaryDirectory(prefix='gemma-logit30-raw-verification-') as tmp:
            root = Path(tmp)
            for name, data in payloads.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            sys.path.insert(0, str(root / 'package'))
            from analyze_traces import trace_control_checks
            original = json.loads(payloads['logit-pair-analysis.json'])
            require(original['status'] == 'valid_bounded_logit_observations', 'unexpected saved status')
            for mode in ('off', 'automatic'):
                trace_name = f'results/gemma-qat4-contiguous-{mode}-logit30-b1-output128/report.json'
                control_name = f'package/controls/{mode}/report.json'
                observed = trace_control_checks(json.loads(payloads[trace_name]),
                                                json.loads(payloads[control_name]), mode)
                observed['trace_report_sha256'] = sha(payloads[trace_name])
                observed['control_report_sha256'] = sha(payloads[control_name])
                require(observed == original['cases'][mode], 'analysis differs for ' + mode)
        result['reproduced_analysis'] = True
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reproduce-analysis', action='store_true')
    arguments = parser.parse_args()
    print(json.dumps(verify(Path(__file__).resolve().parent, arguments.reproduce_analysis), indent=2))
