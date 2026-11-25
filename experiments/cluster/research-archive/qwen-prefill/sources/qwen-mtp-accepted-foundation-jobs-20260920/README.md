# Explicit Foundation compiler jobs

The sole command change from frozen aa3b66f is explicit `swiftc -j 2`. The runner, unreaped-child helper, all27 source inputs and all26 expected controls are exact. No source/assertion/lifetime change; no execution. Root can run:

`python3 -B run.py --output ABSOLUTE_FRESH_CANONICAL_OUTPUT`

The unchanged runner retains60s compile/10s fixture bounds and exact terminal/source checks. This package does not alter the original freeze.
