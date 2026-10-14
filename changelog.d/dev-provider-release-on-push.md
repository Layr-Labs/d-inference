### Automatic dev provider releases

- A push to `master` that changes the provider or its release tooling now builds, signs, notarizes and publishes a dev provider release. Tags still publish production releases unchanged.
- Every dev build has the version `X.Y.Z-dev.<run number>`. `darkbloom --version` shows it, and dev providers update to each newer dev build. Dev runs never receive `PROD_*` secret values.
