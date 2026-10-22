# Selected MTP loading fixture handoff

The loading-only Benchmark SPI and private native executable now compile.
The final build took **21.90 seconds** after the initial full dependency build.
The executable's actual Mach-O minimum is **macOS26.2**. All **3,048** pinned
workspace source/package inputs remained unchanged during the successful build.

**Five publication/error groups, eight real local-pipe groups and eleven pure
argument groups passed.** The argument checks passed under both Python3.14 and
the target system Python3.9.6, using the executable's pure Swift `clock` command
instead of Python's process-relative monotonic origin. Test stderr is empty.

Two failed compilation attempts are retained: a local `pollfd` name shadowed
the output descriptor, and the shared Protocol identity deliberately lacks
`Encodable`. The first correction renames only that local variable. The second
adds a private scalar benchmark identity projection without changing Protocol.
Neither correction changes model loading, ownership or resource policy.

The only existing loader edit extracts its materialization body into a helper
that accepts the already verified source owner. The source checker proves exact
body equivalence apart from indentation and the callback name. Ordinary MTP-off
loading and its target receipt are unchanged. The separate executable cannot
start a collective or generation, and exposes no serving capability or MTP flag.

`bundle/bundle.json` contains the exact three deployable members: executable,
source-matched metallib and MLXLMCommon resource. `result.json` binds their hashes,
the source snapshot, runtime patch and test receipts. `BUILD-RUN.md` defines the
root-owned rank1/cut4 physical job and its required evidence gates. Parent process
supervision, source/bundle validation and journal postflight remain necessary.

**No real registered payload load has run.** Actual selected reads, large buffer
ownership, source accounting and target/assistant/checkpoint retirement remain
the next hardware check. Distributed history, verification and accepted-prefix
MTP transactions remain unimplemented. No MAIN, remote machine or GPU workload
was changed by this increment.
