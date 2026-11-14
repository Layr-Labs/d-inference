### GLM no longer fails requests on idle Macs whose KV pool kept its free memory

- GLM's native paged KV pool kept every segment it ever committed until it was
  unloaded, and each prefix-cache restore attached more. On a 256 GB M5 Ultra
  that free memory stayed charged until a request arriving at an idle Mac could
  not reserve its fixed memory and first step's scratch beside it and failed as
  `capacity_busy` right after admission (about 3,960 GLM requests a day), which
  also put the Mac into the coordinator's capacity cooldown.
- The SDK now returns the pool's free segments before retrying such a request,
  and after the engine has been idle 30 seconds; a request that arrives while
  the previous one is still publishing its prefix checkpoint waits up to 10
  seconds for it instead of failing. `DARKBLOOM_NATIVE_SEGMENT_RELEASE` sets the
  idle seconds, and any value that is not a positive number below a day (`0`,
  `off`) restores the former behavior; it is forwarded to the launchd provider
  job.
