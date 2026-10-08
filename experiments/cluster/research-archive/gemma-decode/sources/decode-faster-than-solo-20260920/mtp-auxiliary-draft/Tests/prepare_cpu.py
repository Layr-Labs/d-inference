#!/usr/bin/env python3
"""Root-only small source preparation. Does not compile, execute or read weights."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-execution-20260920/build/workspace/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime')
PINS = {
    'ClusterRuntimeError.swift': '1344ac5e10936fbc894220f7b5e91862bb522920ea00e7fdb8a647660be27865',
    'ClusterMetadataHashing.swift': '2692e225c505e68572d9093646813d2fb9db05e4839dddf47d510225557f4f41',
    'QwenLongPrefillTensorBudget.swift': '671b0d788eb3950c12f928c61fb12eb6e99d97c386a97a928bec6c8a96e81c09',
}

def main():
    if len(sys.argv) != 2:
        raise SystemExit('Expected one new absolute output directory')
    out = Path(sys.argv[1])
    if not out.is_absolute() or out.exists() or out.parent.resolve() != out.parent:
        raise SystemExit('Output must be create-only under a canonical existing parent')
    sources = {}
    for name, expected in PINS.items():
        data = (RUNTIME / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise SystemExit(f'Changed CPU dependency: {name}')
        if name == 'QwenLongPrefillTensorBudget.swift':
            marker = b'/// Dimension-only input, independent of CLI, model constructors or wire formats.'
            if data.count(marker) != 1:
                raise SystemExit('Checked integer source boundary changed')
            data = data.split(marker)[0]
            name = 'CheckedBytes.swift'
        sources[name] = data
    out.mkdir()
    for name, data in sources.items():
        (out / name).write_bytes(data)
    executable = out / 'assistant-budget-check'
    command = ['swiftc', '-swift-version', '6', '-warnings-as-errors', '-j', '2',
               *[str(out / n) for n in sources],
               str(ROOT / 'Runtime/Gemma4AssistantArtifact.swift'),
               str(ROOT / 'Runtime/Gemma4MTPAuxiliaryBudget.swift'),
               str(ROOT / 'Tests/AssistantBudgetCheck.swift'), '-o', str(executable)]
    artifact = ROOT.parent / 'assistant-artifact'
    receipt = {'compileCommand': command,
               'runCommand': [str(executable), *[str(artifact / n) for n in
                                ['config.json', 'manifest.json', 'model.safetensors.header.json']]],
               'expectedFoundationGroups': 13, 'executed': False,
               'extractedSource': {n: hashlib.sha256(v).hexdigest() for n, v in sources.items()}}
    (out / 'commands.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))

if __name__ == '__main__':
    main()
