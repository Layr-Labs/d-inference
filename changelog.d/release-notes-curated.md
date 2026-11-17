### A release can publish curated notes on GitHub

- Release tooling (CI only; no provider change): when the release's tag holds `docs/releases/provider-vX.Y.Z.md`, its GitHub release body is those notes, then the run's verification header and the compare link, instead of the whole changelog section and the list of pull request titles. Without the file, the body is as before.
