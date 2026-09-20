"""Generate the portable synthetic input for the native fixed-depth probe.

No server, credential, model or network access. The output must not exist.
"""
import argparse
import json
from pathlib import Path


def fixture():
    functions = '\n'.join(
        f'def cache_fixture_{i:04d}():\n    assert transform({i}) == {i}'
        for i in range(300))
    prompt = ('Synthetic implementation fixture.\n' + functions
              + '\nWrite a Python function normalize_inventory accepting a list of dictionaries. '
              'Validate SKU strings and nonnegative integer quantities, merge duplicate SKUs, '
              'sort the result, and include a docstring plus four example assertions. Code only.')
    return {'synthetic_request': {
        'model': 'DarkBloom/Qwen3.8-Flash-Next-Q4-mtp',
        'messages': [{'role': 'user', 'content': prompt}],
        'reasoning': {'enabled': False}, 'temperature': 0, 'seed': 424242,
        'max_tokens': 192, 'stream': True, 'stream_options': {'include_usage': True}}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    with args.output.open('x') as output:
        json.dump(fixture(), output, indent=2)
        output.write('\n')


if __name__ == '__main__':
    main()
