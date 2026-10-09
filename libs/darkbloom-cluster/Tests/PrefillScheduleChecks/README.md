# Prefill scheduling contract checks

Run `./libs/darkbloom-cluster/Tests/PrefillScheduleChecks/run.sh` on macOS.
This directly compiles Foundation sources, the existing native scheduler's pure
window/allowance, and the strict worker parser with an explicit load-value stub.
It does not load a model, initialize MLX/JACCL, open sockets or run the native worker.

Coverage: serial default, exact public-to-native policy mapping, bilateral load
agreement material, both rank allowances, single-chunk behavior, allocator and
capacity refusal, captured prompt frontier, decode exclusion, and closed CLI
selection with the optional complete bootstrap triple, and old serial-worker
argument compatibility against the retained canonical capability. Capability and saved
configuration compatibility run in their existing CapabilityChecks and
ClusterConfigurationChecks runners. The runtime XCTest adds an actual admission
fingerprint comparison; this small runner does not claim to execute that test or
qualify live resource samples, native asynchronous scheduling or throughput.
