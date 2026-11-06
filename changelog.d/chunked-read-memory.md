### Chunked file reads release each chunk

- Before, a file read in chunks kept every chunk in memory until the thread that read it went idle. On macOS each chunk read returns an autoreleased buffer, and a Swift task or a Dispatch block does not release these buffers between chunks. Thus memory grew with the size of the file.
- Now each chunk read releases its buffer before the next read. This applies to the model manifest hash in `darkbloom-publish`, the speculative-decoding store's artifact hash, the binary and file hashes, the metallib snapshot copy, the streamed SSD KV cache read, the cluster worker hash, the MTP benchmark weight hash and the App Attest worker's executable hash. It also applies to the output readers of desktop commands and sandbox commands.
- The output readers of desktop commands and sandbox commands keep only the last 32 KiB of output. Before, the buffer that held these 32 KiB also kept all the earlier output. The stderr tail that the provider keeps for a failed helper process had the same problem, and it is fixed the same way. Its stderr reads also release each buffer.
- The digests and the copied bytes do not change.
