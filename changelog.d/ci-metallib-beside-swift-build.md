### Provider CI: Metal library built beside the Swift build

- The provider build job starts the source-matched `mlx.metallib` build in the background, right before its Swift build, and waits for it before staging the library into the test products. Before, the library built after the Swift build, 67 to 78 s on every cold run's critical path. A failed library build still fails the job; the library, its cache key and its checks are unchanged. The cluster lane, on a smaller VM, builds the library after its Swift build as before.
