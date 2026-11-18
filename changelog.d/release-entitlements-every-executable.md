### Provider releases check every signed executable

- After signing, the release lane checks every executable in `Darkbloom.app` (the CLI, the Secure Enclave helper, the fan helper, the cluster worker and the cluster plan) and stops the release unless each is signed by the Developer ID and leaves `get-task-allow` off. `scripts/provider-signing-validation.py bundle-entitlements --app <app>` runs the check.
