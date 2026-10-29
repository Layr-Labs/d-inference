# V2 correction before any physical smoke

Root review found that V1's validator and its invented saved fixture used Swift
enum case names `serial`/`oneChunkLookahead`. Actual Codable values are
`serial_v1`/`one_chunk_lookahead_v1`. V1 would reject the real selected candidate.
This was a private validator bug, not a product failure; no physical smoke ran
with V1. Its manifest5e7a71ff69486895a5088a93fe309c14204e1518702fbfe6bfeea2a65136db58
and all original files remain unchanged.

V2 requires the exact selected value `one_chunk_lookahead_v1` and the two actual
peer identities. Tests reuse the full saved binding from the captured stopped
leader report at `installed-distributed-diagnostics-operator-checks-20260915/`
`darkbloom-24.status.stdout.json`; they invent only live observation fields.
The stopped report has no live object and must fail readiness validation.
It declares maximumRequests16, maximumLifetimeSeconds300, rank0darkbloom-24,
rank1darkbloom-48. Those facts are asserted directly before live fixture creation.

`status_capture.py`, guards, supervisor and all cleanup mechanics are unchanged
from V1. `run.py` additionally pins the actual stopped-report fixture. The new
12-case execution under `checks-2/` passed; old10-case `checks-1/` results are
preserved solely as pre-correction history. No remote/native operation occurred.
