### Concurrent Nemotron Super images

- Nemotron Super serves two image requests at once on owners serving at least three requests (the managed slot serves up to eight). Vision preparation stays serial; native decode runs concurrently. Each full media reservation stays charged through settlement, and video stays exclusive with other media.
- On by default; `DARKBLOOM_NEMOTRON_SUPER_CONCURRENT_IMAGES=0` (forwarded by the LaunchAgent) restores the 0.10.12 single-media admission.
