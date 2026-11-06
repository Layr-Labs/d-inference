# Report handoff

The 113-line report and navigation/status-only patch are ready for root review and main integration. No main files were modified. Earlier source review and replay bytes remain unchanged; wakeup review is an additive supplement. Both root analyzer replays reproduce their saved comparison bytes; the independent raw replay recomputes integer timestamps, Fraction medians, both-rank metadata joins, sampled resources and cleanup. No native/GPU/network was used.

Apply the one new report, add its reports index entry, and update only the execution plan Status line. Root should run the repository docs/link check after integration. A frozen dated report must not be edited after landing. The new report retains all three comparison hashes and keeps performance, HTTP TTFT, fresh-UUID numerical and recovery scope explicit.
