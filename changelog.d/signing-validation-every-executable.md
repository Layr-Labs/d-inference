### Signing validation checks every signed executable

- The manual provider signing validation now runs the release lane's check on every executable in `Darkbloom.app` after signing and before notarization: each must be signed by the Developer ID and leave `get-task-allow` off.
