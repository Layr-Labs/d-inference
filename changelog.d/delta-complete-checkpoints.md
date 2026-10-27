### Delta complete checkpoints

- A request that restored a Qwen 3.8 complete checkpoint (`native-paged-full-recurrent-v1` or `native-contiguous-full-recurrent-v1`) now writes its later checkpoints as deltas: only the rows the restored file lacks, plus the recurrent state. On a six-turn 30K–55K-token conversation, checkpoint writes fell from 20.0 GB to 5.4 GB with identical outputs and unchanged TTFT on both layouts, so the daily write cap lasts about four times longer. `DARKBLOOM_PREFIX_CACHE_SSD_INCREMENTAL_CHECKPOINTS=0` restores complete files.
