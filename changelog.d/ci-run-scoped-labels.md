### Provider CI: Darkbloom runners scoped to their workflow run

- The route job asks the Darkbloom plane for run-scoped labels (`X-Darkbloom-Run-Scoped-Labels: 1`). The plane then names the run's ID in the last label, after any size, such as `darkbloom-macos-arm64-4x24-run-<run ID>`, and creates each runner with that label, so an idle runner of another run cannot take this run's job and lose it when that run ends.
- A lane uses a grant only when its labels are the exact Darkbloom labels of its profile and size, unscoped or scoped to this run. A plane that ignores the header keeps answering the unscoped labels; another run's ID, or a scope anywhere else, keeps `blacksmith-12vcpu-macos-27` or the lane's Linux fallback.
- A re-run keeps the run ID, so its jobs still match the labels the route saved.
