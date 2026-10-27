"""Reuse one exact completed full reference under its original package binding."""
from pathlib import Path
from binding_common import parse, same
from binding_inputs import snapshot

OLD = Path('/Users/developer/DarkbloomDev/cluster-research/gemma4-attention-identity-physical-draft-20260917')
FULL_BOUND = OLD / 'actual-inputs-1/bound'
FULL_DIRECTORY = OLD / 'physical-actions-1/collect-full/action/returned'
FULL_RUN = OLD / 'physical-actions-1/full/action/receipt.json'
FULL_RUN_SHA = 'cbd5d3964fb241c9e70bfba4f478dda1ba21f5b366917ff4e9c9981e40c6778a'
FULL_BINDING_SHA = 'b1996ec96694c62e7b8a8b9a60ebd24b643e9509263fd60e3a34c1dcfc980781'
FULL_TERMINAL_SHA = '32d64916d734efdc6758e9d729f51de3acbe5e520e82651d7d532dfb81b7e045'
FULL_COLLECTION_SHA = '6ffe77a433384b912f041547c0a23c6c044824cc83ae73080fd1e4e243c1ebb3'


def reference_bound(current_bound, directory):
    same(directory, FULL_DIRECTORY, 'Fixed original full-reference directory')
    old = snapshot(FULL_BOUND / 'binding-receipt.json', 65536)
    same(old['sha256'], FULL_BINDING_SHA, 'Original full binding receipt')
    binding = parse(old['raw'])['binding']
    same(parse((FULL_BOUND / 'binding.json').read_bytes()), binding, 'Original full binding')
    same(parse((current_bound / 'binding.json').read_bytes()), binding,
         'Exact unchanged native/source/build/request expectation/prompt/model/dtype/comparator')
    same(snapshot(directory / 'terminal.json', 65536)['sha256'], FULL_TERMINAL_SHA,
         'Actual completed full terminal')
    same(snapshot(directory.parent / 'returned-collection.json', 65536)['sha256'],
         FULL_COLLECTION_SHA, 'Original exact full collection inventory')
    return FULL_BOUND


def reference_run(current_bound, directory, path, wanted):
    reference_bound(current_bound, directory)
    same(path, FULL_RUN, 'Fixed original full run receipt')
    same(wanted, FULL_RUN_SHA, 'Fixed original full run pin')
    same(snapshot(path, 4 * 1024**2)['sha256'], wanted, 'Original full run unchanged')
    return FULL_BINDING_SHA
