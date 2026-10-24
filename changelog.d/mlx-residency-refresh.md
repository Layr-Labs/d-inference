### No more re-wiring delay on the first request after an idle gap

macOS drops the GPU residency of a provider's model buffers about two seconds after the GPU goes idle, so the
first request after a pause waited for the model to become resident again before its first token. The provider
now turns on MLX's residency refresh (`MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS=1000`, a CPU-side request every
second, no GPU work) when it starts serving. Set the variable to `0` to turn it off.
