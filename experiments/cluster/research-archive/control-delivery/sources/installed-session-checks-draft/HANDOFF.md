# Repository-local installed-session checks

Promote the seven new files in `integration.json` / `integration.patch` under provider-swift/Tests/ClusterInstalledSessionChecks. The patch preserves run.sh as executable. No runtime or Package.swift changes. The README gives the one-command entry and exact proof limits.

The runner compiles current MAIN Foundation modules and the exact installed/configuration/deadline sources, reusing the existing process contract values and fake worker. No runtime implementation, weights or usable credentials are copied. Five prior fixture files carry forward the checks-7 scenarios; four remain byte-identical. The fifth only strengthens the partial-start assertion and distinguishes exact missing-ACK/natural-zero-exit from ACK/nonzero-seven-exit. The separate assertion patch preserves this small test delta.

The exact runner and fixture bytes passed in an isolated workspace with read-only MAIN source symlinks: qualification-3/checks.json, 14.657 seconds total, exit0, empty stderr, all55 current source/helper pins unchanged, temporary build directory removed. Six lifecycle scenarios plus metadata/bounded IO checks passed. The first runner attempt hit macOS Bash nounset behavior on an empty local array before compilation; the dependency list now starts with nonempty common linker arguments. Its stderr/failure receipt remains retained.

Root's final source review is pending at freeze. No main edits, full Provider/SwiftPM build, native model/GPU, SSH or network execution by this task. Existing full Provider/CLI checks remain separate.
