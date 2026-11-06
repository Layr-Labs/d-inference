### metal-cpp from the Darkbloom sandbox image

- `scripts/fetch-metallib.sh` uses the metal-cpp archive that Darkbloom's macOS sandbox images carry, when it is the archive the nested MLX core names and its SHA-256 matches the pin. The metallib build then makes no download from developer.apple.com, where downloads through the sandbox's egress ended early (`transfer closed with … bytes remaining`). Elsewhere, MLX's configure downloads the archive as before.
- Changing the script changes the metallib cache key once: the first CI runs after this change rebuild the metallib.
