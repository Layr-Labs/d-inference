# Cluster configuration checks

Run `provider-swift/Tests/ClusterConfigurationChecks/run.sh` from any directory.
The runner compiles the actual Foundation configuration and Protocol sources,
then exercises nine filesystem groups and eleven schema/store groups. It uses
temporary files and fabricated capability/key metadata; it neither contacts a
peer nor loads a model or private key.

Coverage includes duplicate keys and invalid types, selected Plan and binary
pins, the native 63-byte device-name boundary, immutable publication, refused
links/FIFOs/permissions, concurrent locks, sticky device journals, trust-file
changes and provider-update failures. The separate ProviderCore and CLI tests
exercise real TOML preservation and command parsing through SwiftPM.
