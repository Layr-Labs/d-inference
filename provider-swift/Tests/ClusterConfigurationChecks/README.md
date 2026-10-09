# Cluster configuration checks

Run `provider-swift/Tests/ClusterConfigurationChecks/run.sh` from any directory.
The runner compiles the actual Foundation configuration and Protocol sources,
then exercises nine filesystem groups, the provider configuration writer and
twelve schema/store groups. It uses temporary files and fabricated
capability/key metadata; it neither contacts a peer nor loads a model or
private key.

Coverage includes the generation mode (omitted means the pipeline and leaves
a setup's bytes unchanged; an unadvertised mode is refused naming the mode and
the worker; a capability record this build cannot read is explained as a mixed
install), duplicate keys and invalid types, selected Plan and binary
pins, the native 63-byte device-name boundary, immutable publication, refused
links/FIFOs/permissions, concurrent locks, sticky device journals, trust-file
changes and provider-update failures. The writer check proves that an ordinary
provider save creates and keeps `provider.toml` owner-only, so the strict
cluster reader still accepts it, and that a failed save changes nothing and
leaves no staged file behind. The separate ProviderCore and CLI tests exercise
real TOML preservation and command parsing through SwiftPM.
