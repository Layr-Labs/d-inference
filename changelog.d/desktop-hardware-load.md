### Desktop hardware load

- Serve whole-machine load to the desktop app over the authenticated control API: per-core CPU load with tier and cluster layout, GPU utilization and memory, ANE activity, memory pressure, thermal state, and Darkbloom's share of GPU time. Sampling runs in the desktop API process only while the app is looking, without root, and never reaches heartbeats, logs or the coordinator.
- Add best-effort GPU power and frequency plus estimated DRAM and ANE bandwidth; values stay unknown (`null`) until a counter has been seen moving. `darkbloom doctor --hardware` prints the same report.
