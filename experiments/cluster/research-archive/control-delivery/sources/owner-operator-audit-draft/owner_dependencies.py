"""Pinned, small phase-metadata dependency only; no model/numerical oracle."""
import hashlib
import importlib.util
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parent.parent
PINS={
 'owner-operator-plumbing-draft/manifest.json':'3f96ed0d731eae7502332ddfa1cbc8c99bc2cadd7c57cbfcdd74f5b97709ea22',
 'owner-operator-plumbing-draft/files/experiments/cluster/inference/Sources/ClusterInference/Tracing/QwenPrefillOwnerCapture.swift':'6840aaca07018d703f08333c09ecdffce0cd345e593001cea7901f7e33b548f8',
 'owner-operator-plumbing-draft/files/experiments/cluster/inference/Sources/ClusterInference/Tracing/QwenPrefillTraceCaptures.swift':'7089c4e2d21695ce49c949d681dbde08725d666a7085e4365238fb2cbfb6bb60',
 'owner-operator-plumbing-draft/files/experiments/cluster/inference/Sources/ClusterInference/Tracing/QwenPrefillOwnerFrameBinding.swift':'9ff1833cbdfde042f695552f57d9548928cfd9b8a98b5487771fee2ab880a410',
 'owner-operator-plumbing-draft/files/experiments/cluster/inference/Sources/ClusterInference/Tracing/QwenPrefillPhaseFile.swift':'2fcd533f6910c9abcbffd4cd1b449d1bc60aef80717be65a40ba21087ad07d53',
 'owner-operator-plumbing-draft/files/experiments/cluster/inference/Sources/ClusterInference/Main.swift':'302b5b3a8e63fe511f938487d00c6e4bec8413716f68c914ad5a71ad5e70538e',
 'owner-operator-plumbing-draft/files/experiments/cluster/inference/Sources/ClusterInference/QwenLongPrefillSoloCheck.swift':'e8341b6c244aeaeb36e2e03871cebebed3ce525c6b058e37f9f531374a906d81',
 'owner-operator-plumbing-draft/files/experiments/cluster/inference/Sources/ClusterInference/QwenLongPrefillRankCheck.swift':'580b865aa0aea9065aeaf369c1d5922911f2faa996fff4add20e9fac52f6b70a',

 'phase-clock-audit-draft/manifest.json':'a540ab7a9ddf115ea3e34712fe152dbcb21d532f03a3e0749b6fd347645e6176',
 'phase-clock-audit-draft/phase_contract.py':'bbdf4acd1cc6717c5862070584feb177c7e264cc42566c32554ec242373fa2f0',
 'phase-clock-audit-draft/phase_base.py':'43a36fcc5b94a4a0986508f90d3e4bd404cd0fe0bd6abdc8f9b61cbc4379b966',
 'phase-clock-audit-draft/phase_spans.py':'867c31114c32325f11fd11c8f9c24471e9bfc026f98055c90b425ffb8c9b75ea',
 'phase-clock-audit-draft/phase_clock_audit.py':'00d973168ef530fb5abae5c0bb62ba26d705ae6db0895f87298a6520e78d3cc5',
 'owner-operator-collector-draft/manifest.json':'41e2d6a60e833fb6eb55464e1217538d65be75efe06596de355fcb298fd991e3',
 'owner-operator-collector-draft/QwenPrefillOwnerTypes.swift':'5dfcfe66ebc74c32f9cb1c75b046b5db83a1f4d7d2eb4047ca9e639f041a575f',
 'owner-operator-collector-draft/QwenPrefillOwnerRecorder.swift':'e5e134c91b265a763711361a2422ced218ea9dcb6b33f02180069c7159a8fddc',
 'owner-operator-phase-draft/manifest.json':'0062f80ef584aedd4acb7d6967cd1f0b874959b30632352983e820e804da17b6',
 'owner-operator-phase-draft/CBv2OwnerPhaseObservation.swift':'074cd6d297e3b019022c6a9d921ebb1f32b64fd4d23c0a84a9b0a36e3f7ad172',
 'owner-operator-phase-draft/owners.patch':'b31e495b29121c4b6745d3c5a0d58595f1a0435e150b7194f1484a35105bfefe',
 'owner-operator-hooks-draft/manifest.json':'a15b5b520f5a1ce937dc850bcb95870e075bc6d0ac8ae09b6d54de7956abca52',
 'owner-operator-hooks-draft/hooks.patch':'6e2f0a2c22e757cf919ed1b153deb945093fbc008b076656cdbd7addb90cee4b',
 'owner-operator-hooks-draft/QwenPrefillOwnerObserverFactory.swift':'ca69d886a085ad7651e589df21f71b6610e033a130c80bb5a9627b3dba731b6b',
}
_PHASE=None


def bounded(path,maximum):
    with Path(path).open('rb') as f:raw=f.read(maximum+1)
    if not 0<len(raw)<=maximum:raise ValueError('Bounded nonempty input required')
    return raw


def verify_pins():
    out={}
    for name,wanted in PINS.items():
        raw=bounded(ROOT/name,128*1024);actual=hashlib.sha256(raw).hexdigest()
        if actual!=wanted:raise ValueError('Frozen dependency changed: '+name)
        out[name]=dict(sha256=actual,byteCount=len(raw))
    return out


def modules(fixture=False):
    """Temporary import names isolate legacy absolute imports from caller state."""
    verify_pins()
    names=['phase_contract','phase_base','phase_spans','phase_clock_audit']
    if fixture:names.append('phase_fixture')
    previous={name:sys.modules.get(name) for name in names};loaded={}
    try:
        for name in names:
            path=ROOT/'phase-clock-audit-draft'/(name+'.py')
            if name=='phase_fixture' and hashlib.sha256(bounded(path,65536)).hexdigest()!='63a07fd5436ae88f47ecfc648283ca08e7e75f0f7e0cc32e82bf2af28cdc87af':
                raise ValueError('Frozen synthetic metadata fixture changed')
            spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec)
            sys.modules[name]=module;spec.loader.exec_module(module);loaded[name]=module
    finally:
        for name,value in previous.items():
            if value is None:sys.modules.pop(name,None)
            else:sys.modules[name]=value
    return loaded


def phase():
    global _PHASE
    if _PHASE is None:_PHASE=modules()
    return _PHASE['phase_clock_audit'],_PHASE['phase_contract']
