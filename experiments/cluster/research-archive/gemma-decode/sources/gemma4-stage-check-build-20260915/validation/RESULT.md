# Compiled Gemma stage result

The exact frozen native candidate compiled and linked successfully on the first attempt. Compilation took 209.383 seconds; the metadata-only executable took 0.601 seconds and passed seven policy groups plus all 29 cuts of the pinned actual artifact configuration. No source correction was needed. The independent Foundation mapper closure passed 191 accepts and 36 refusals.

All 3,090 assembled source files and 8,755 dependency files remained unchanged. The executable has exactly one macOS LC_BUILD_VERSION with minimum 26.2. Build, vtool and fixture children were reaped and their groups absent. Metadata and vtool stderr were empty; existing SwiftPM and legacy Swift warnings remain in the retained build logs. Compiler ownership has been released.

The executable path and digest, exact source/dependency snapshots and execution receipt are bound in result.json. This is a local compiled-check artifact, not a deployable distributed worker. No model Module was constructed, no tensor payload was read, and no native forward or GPU/model/remote test ran. Native stage construction, loaded assignment, actual KV/boundary dtype, windowed state and numerical whole/split equality remain qualification work.

The next source slice reuses the existing native KV recorder/evaluation loop through a throwing residual-forward callback. Shared request geometry/state validation must gain explicit per-layer observed types and window retention before Gemma can reuse the current owned-state engine. The original Qwen behavior and fingerprints must stay unchanged.
