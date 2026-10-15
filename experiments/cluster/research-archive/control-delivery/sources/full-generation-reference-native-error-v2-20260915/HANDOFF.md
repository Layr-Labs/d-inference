# Native-error preference correction

Apply this one-file overlay after the frozen full-generation reference package
`6b658a4de92d0bb3253f6983a2f65d79e58655f83cbc0521c7d9e5beace6a522`.
The original package remains unchanged.

`MLX.withError` checks its native error box after a normal body return. The new
inner `do/catch` also checks that box when a Swift validation or callback throws,
so a recorded native fault takes precedence. The existing outer catch still
retires request state and preserves the primary failure separately from cleanup.

Removing only this wrapper and its indentation restores the frozen request
function exactly. Admission, forward math, evidence, clocks and ownership order
are unchanged. The original Foundation 7/24 result remains applicable to its
unchanged pure sources; it does not test native-error delivery. Syntax parsing
is recorded separately; native typecheck and execution remain pending.
