#!/usr/bin/env python3
"""Small-file source/inverse check only; does not invoke Swift, MLX or children."""
import ast
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    bound = json.loads((ROOT / 'source-inputs.json').read_text())
    for row in bound['sources']:
        assert digest(ROOT / row['source']) == row['sha256'], row['source']
    for row in bound['context']:
        assert digest(Path(row['path'])) == row['sha256'], row['path']
    for row in bound['overlays']:
        assert digest(ROOT / row['source']) == row['afterSHA256'], row['source']
        if row['beforeSource']:
            before = (ROOT / row['beforeSource']).read_text()
            after = (ROOT / row['source']).read_text()
            for edit in reversed(row['edits']):
                assert after.count(edit['after']) == 1
                after = after.replace(edit['after'], edit['before'], 1)
            assert after == before, row['source']
    # Independent integer coverage: supported lane partitions visit each K
    # input exactly once per output row, with complete packs and group64 bounds.
    geometries = [(2816,704,4,8),(704,2816,4,8)]
    dense = [(2816,4096,4),(2816,2048,4),(2816,8192,4),(2816,1024,4),
             (4096,2816,4),(8192,2816,4),(2816,2112,8),(2112,2816,8),(2816,128,8)]
    for k,n,bits in dense:
        one = 32 // bits
        geometries.append((k,n,bits,2*one if k%(one*64) == 0 else one))
    for k,n,bits,vpt in geometries:
        visited = []
        for base in range(0,k,vpt*32):
            for lane in range(32):
                start = base+lane*vpt
                if start < k:
                    assert start+vpt <= k and start//64 == (start+vpt-1)//64
                    visited.extend(range(start,start+vpt))
        assert visited == list(range(k)) and n%8 == 0
    for file in ROOT.glob('*.py'):
        ast.parse(file.read_text(),filename=str(file))
    print(json.dumps({'sourceOnly':True,'sources':len(bound['sources']),
                      'contexts':len(bound['context']),'inverseOverlays':2,
                      'laneCoverageGeometries':len(geometries),
                      'swiftOrMetalCompiled':False,'gpuExecuted':False},sort_keys=True))

if __name__ == '__main__':
    main()
