"""Produce bounded metadata contracts. Never opens a weight payload."""
import argparse
import json
from pathlib import Path
from artifact import load_artifact
from geometry import state_geometry
from partition import make_partition


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(mode=0o700, parents=False, exist_ok=False)
    artifact = load_artifact()
    cuts = []
    for cut in range(1, 30):
        plan = make_partition(artifact, cut)
        cuts.append({"cut": cut,
            "rankTensorCounts": [s['destinationTensorCount'] for s in plan['stages']],
            "rankHeaderDerivedPayloadBytes": [s['headerDerivedPayloadBytes'] for s in plan['stages']],
            "rankSlidingLayerCounts": [sum(x['kind'] == 'sliding_attention' for x in s['layers'])
                                       for s in plan['stages']],
            "rankFullLayerCounts": [sum(x['kind'] == 'full_attention' for x in s['layers'])
                                    for s in plan['stages']],
            "metadataContractSHA256": plan['metadataContractSHA256']})
        if cut in (12, 15):
            write(args.output / f'partition-cut{cut}.json', plan)
            for p, c in [(32, 16), (8192, 512)]:
                write(args.output / f'state-cut{cut}-p{p}-c{c}-o128.json',
                      state_geometry(cut, p, c, 128))
    write(args.output / 'all-cuts.json', {"cutSelectionQualified": False, "cuts": cuts})
    write(args.output / 'input-pins.json', {"scope": "small metadata/header bytes only",
          "files": artifact['pins'], "weightPayloadFilesRead": 0,
          "tokenizerPayloadFilesRead": 0, "wholePayloadHashesVerified": False})
    print(json.dumps({"ok": True, "cuts": len(cuts), "inputPins": len(artifact['pins']),
                      "scope": "metadata-only"}))


if __name__ == '__main__':
    main()
