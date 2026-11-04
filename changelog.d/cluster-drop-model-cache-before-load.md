### Large models no longer loop on "not enough memory" on 128 GB Macs

- Large models such as MiMo V2.6 Flash no longer refuse to start on two 128 GB Macs. Each start used to read the whole model into macOS's file cache first. Loading a Mac's share then made macOS compress other memory, the memory check stopped counting the cache, and the start was refused, again and again. On 2026-11-01 a pair of 128 GB M4 Max Macs was refused 680 times in a row and never served.
- Each Mac now clears its model's files from the file cache before its part starts, and each load clears the cached pages of the weight files it reads. The loads read from the SSD into free memory, so nothing has to be compressed. Only the model's own files are cleared. Their contents are never changed and no password is asked for.
- The same cause sometimes refused Qwen3.8 27B for one start on a busy 128 GB MacBook Pro. That refusal is fixed too.
- A load can take a few seconds longer, because its weights now come from the SSD instead of memory.
- The worker log now records each load's memory check in one `darkbloom-load-memory-v1` line: what it needed, what was free, how much file cache there was, and how much was compressed during the load. A refusal now explains itself.
