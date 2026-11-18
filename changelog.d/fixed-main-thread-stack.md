### Fixed main-thread stack size

- Every Darkbloom executable (the provider, its enclave and fan helpers, and the cluster worker and planner) now links a fixed 8 MiB main-thread stack, the size launchd's default limit gives, so it starts the same way whatever stack limit it is launched with.
