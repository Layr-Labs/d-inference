# Explicit release path for the tiny regression launcher

V3 adds optional `--release` for a source-matched bundle built on another development host. The omitted-argument path is unchanged. An explicit directory resolves strictly before the original expected-native hash check and is recorded in the receipt. Both fresh snapshot and strict optional reuse keep all existing resource, output, timeout, source, bundle and cleanup checks. The normal BF16 diagnostic still causes the original empty-stderr parent failure; numerical replay remains separate. No native execution occurred while preparing this package.

This addresses the retained peer setup refusal: the peer has source and the transferred build in an isolated package, but no `.build/release/cluster-inference`. It does not claim a native rebuild on the peer or install a substitute into SwiftPM's build directory.
