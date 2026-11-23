### Provider CI: test jobs see their build's end sooner

- A provider or cluster test job waits for its lane's build job by reading the run's jobs every 15 s (`scripts/ci-test-products.py wait`). Once the build job's upload step (`Upload provider test products` or `Upload cluster test products`) has started, it now reads them every 3 s until the build ends. In the 74 successful pull request provider builds of 2026-11-23 the build ended 39 s after its upload step started (p50; 108 s p90).
- At 15 s the last provider test job saw the build's end 11.8 s late (p50, 2 to 18 s). At 3 s that is about 6 s sooner, for about 10 more requests per test job.
- The products, their checks and the tests are unchanged, and a build that does not succeed still fails its test jobs at once.
