# Public observed-loader test support

Copy the two files under `proposed/` to their matching repository paths and apply
`docs.patch`. The root already integrated the eight unchanged fixture sources
from the frozen observed-loader draft. This package adds no fixture copies,
retained data, runtime code or CLI flags.

The runner compiles the exact 30 Foundation source inputs used by the successful
root check, through their public production/test paths. It enables Swift 6,
parse-as-library and warnings-as-errors, and reuses the existing
`Tests/RegisteredDenseProfiles/retained-inputs.json`. Source checks matched all
30 integrated file hashes to the frozen CPU compilation inputs and matched the
shared metadata hash. The optional source-directory argument has the same
review-oriented meaning as the existing RegisteredDenseProfiles runner.

The author ran only Bash syntax and CPU source/path/hash/link checks. Neither the
new shell runner nor Swift was executed by the author. The documented 22/104
result comes from the separately completed root Foundation run, execution SHA
`58954a72242fa1eab6bf68a05f0e17c0e70839aef07db9ae7908cc027d75e30f`;
its stdout SHA is `03f736e2535a4ba10c1f676897a41754948c672d2d0cd8b074034c4a27956271`.
Native loader regression and later resource/27B execution qualification remain
separate.
