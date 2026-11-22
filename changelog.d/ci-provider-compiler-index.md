### Provider CI compiler indexing

- The macOS provider test build skips the compiler index that the test-products archive already excludes. Shards still discover the linked tests and report their coverage.
