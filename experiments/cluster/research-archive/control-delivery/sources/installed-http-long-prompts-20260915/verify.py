"""Recount retained plaintext requests through pinned full Jinja and tokenizer."""
import argparse
import json
from pathlib import Path
from prompt_inputs import load_pinned, request, sha
from prompt_render import Renderer

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    record = json.loads((args.directory / 'preparation.json').read_bytes())
    renderer = Renderer(load_pinned())
    counts = []
    for row in record['fixtures']:
        for member in row['files']:
            raw = (args.directory / member['path']).read_bytes()
            assert len(raw) == member['bytes'] and sha(raw) == member['sha256']
        name = 'prompt-' + str(row['targetTokens'])
        prompt = (args.directory / (name + '.txt')).read_text()
        rendered, ids = renderer.encode(prompt)
        assert rendered.encode() == (args.directory / (name + '.rendered.txt')).read_bytes()
        assert ids == json.loads((args.directory / (name + '.ids.json')).read_bytes())
        assert len(ids) == row['targetTokens'] == row['pythonTemplatedTokenCount']
        assert request(prompt) == json.loads((args.directory / (name + '.request.json')).read_bytes())
        assert sha(','.join(map(str, ids)).encode()) == row['tokenIDsCommaSeparatedSHA256']
        counts.append(len(ids))
    assert counts == [4096, 8192]
    print(json.dumps(dict(verifiedPythonCounts=counts, swiftTokenizerExecuted=False, serverCountObserved=False)))

if __name__ == '__main__':
    main()
