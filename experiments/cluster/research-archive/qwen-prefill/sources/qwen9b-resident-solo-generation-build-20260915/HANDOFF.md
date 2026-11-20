# Compiled matched resident solo9B candidate

The frozen d5d28134818c58f4359154df6da83cfce6039157a6ea612578b1cb8c588e92dc
source package compiled on the first attempt with no correction. Build1 passed
in231.237seconds; actual CPUcheck1 passed15 accepted/24 rejected cases in1.086
seconds with empty stderr. Source3290/dependency9502 pins stayed unchanged.
Warnings from existing SwiftPM/MLX sources are retained in build1 logs.

Native SHA:
`8952b0f260502b06f7dbe7eb9e0cbef1b41564001570ad52a3c2739a247252d3`.
Build manifest SHA:
`796b0d89409e63445dc4baec18bc0e3baa989f82b1fe516f1a8fe79f33e4ceb9`.
Bundle manifest SHA:
`71617e2747ea993ad9012966997a7676442b9f0229c52989a2cebe2a21906cb7`.
Bundle contains three exact files,228315428bytes, plus its manifest. Binary
inspection shows macOS26.2 minimum and only system dylibs. Source-matched Metal
resources are unchanged from the aligned full-reference package.

No GPU/model, remote operation or MAIN mutation occurred. CPU checks do not
establish native kernel dispatch, native state retirement or performance. The
next step is root's reviewed48GB physical parent in
`qwen9b-resident-solo-supervisor-draft-20260915`, one load/warm1/measure3, with
the original8192 prompt IDs and128 expected target IDs. Compiler slot is released.
