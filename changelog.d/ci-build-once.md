### Provider CI: build once, test on small Macs

- Each lane builds its debug test products once, on a 12 vCPU Blacksmith Mac: Build cluster test products and Build provider test products. The test jobs download the products and run them with `swift test --skip-build`; they compile no package. A test job refuses products of another commit or of another Swift, Xcode or SDK version, and warns when only their builds differ.
- The jobs that build or run the products work at one fixed path, `/private/tmp/dinf`, because SwiftPM's products hold absolute paths and Blacksmith and Darkbloom check out to different paths.
- The cluster tests start as soon as the cluster products are up. The worker capability and prefill schedule checks, which compile a release build, run in Cluster Release Build Checks on a 12 vCPU Blacksmith Mac. The `Provider Tests` gate requires it.
- Refresh build caches is gone: a push whose tree a pull request run already tested runs the build jobs of the components it changed, without an upload.
- Cluster Runtime Tests runs in 3 shards: the Gemma 4 base suites (592 of the base tests' 970 s) run in their own process on shard 3. Cluster Focused Checks runs in 2 shards: the runner scripts, and the stage metadata, provisioning and onboarding runners.
- The provider shard weights are measured again, so the last selection no longer runs every suite the old weights missed. The last shard's audit warns when a serial suite has no weight.
- Only the 7 blocking test shards ask Darkbloom for a Mac; the build jobs, Cluster Release Build Checks and Cluster GPU Tests use Blacksmith directly.
- Every macOS job samples its memory and CPU use and prints the peaks; the samples upload as `resource-samples-*`. The sampler never fails a job. The products hand-off prints the archive size and the upload and download times.
