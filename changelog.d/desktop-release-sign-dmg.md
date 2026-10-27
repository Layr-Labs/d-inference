### Desktop release signs the DMG

The desktop release workflow now signs the DMG with the Eigen Labs Developer ID
before notarizing it. The first dry run built, signed and notarized the app, but
Gatekeeper rejected the unsigned DMG (`source=no usable signature`).
