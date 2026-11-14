### Reading `provider.toml` no longer grows the provider's memory

- Every parse of `provider.toml` used to stay in memory for the life of the process: TOMLKit 0.6.0, the library that reads it, never freed a parsed table. Saving a cluster setup parses the file again, so a paired Mac that kept sending setups made the other Mac's provider grow by tens of KB each time. The provider now builds a copy of TOMLKit, in `libs/TOMLKit`, that frees each parse once nothing uses it. What the file reads as and how it is written are unchanged.
