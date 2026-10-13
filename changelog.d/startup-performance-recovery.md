### Fixed

- Keep one-token startup health-check timings out of serving throughput estimates, and bootstrap supported loaded models, including ordinary dense and MoE Qwens, with bounded, preemptible measurements so slow first-use samples do not leave warm providers waiting for their first jobs.
