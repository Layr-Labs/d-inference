### Concurrent Nemotron Super images

- Add the opt-in `DARKBLOOM_NEMOTRON_SUPER_CONCURRENT_IMAGES=1` switch for two image requests on owners serving at least three requests. Vision preparation stays serial; native decode may run concurrently. Each full media reservation stays charged through settlement, and video stays exclusive with other media.
- Unset or `0` keeps the current single-media behavior. Full-checkpoint memory, output parity and throughput qualification of the enabled path remain pending.
