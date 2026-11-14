### Configuration parsing no longer accumulates memory

- Reading the provider's configuration file no longer leaves memory behind each time; the provider uses a fixed copy of its TOML library.
