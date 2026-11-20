"""Create argument-only cases from a concrete source-bound resident job."""
import argparse
import json
from pathlib import Path


def main():
    p = argparse.ArgumentParser(allow_abbrev=False)
    p.add_argument('job', type=Path); p.add_argument('output', type=Path)
    args = p.parse_args(); base = json.loads(args.job.read_bytes())
    assert base['schema'] == 'gemma4_resident_benchmark_v1'
    args.output.mkdir(mode=0o700)
    cases = [('omitted-serial', 'stage0', None, True),
             ('explicit-serial', 'stage0', 'serial', True),
             ('lookahead-producer', 'stage0', 'oneChunkLookahead', True),
             ('lookahead-receiver', 'stage1', 'oneChunkLookahead', True),
             ('full-serial', 'full', 'serial', True),
             ('full-lookahead-refused', 'full', 'oneChunkLookahead', False),
             ('unknown-policy-refused', 'stage0', 'twoChunkLookahead', False)]
    rows = []
    for name, mode, policy, accepted in cases:
        value = dict(base, mode=mode); value.pop('prefillPolicy', None)
        if policy is not None:
            value['prefillPolicy'] = policy
        path = args.output / (name + '.json')
        with path.open('x') as stream:
            json.dump(value, stream, sort_keys=True, separators=(',', ':')); stream.write('\n')
        rows.append(dict(name=name, job=str(path), expectedAccepted=accepted))
    with (args.output / 'cases.json').open('x') as stream:
        json.dump(rows, stream, indent=2); stream.write('\n')


if __name__ == '__main__':
    main()
