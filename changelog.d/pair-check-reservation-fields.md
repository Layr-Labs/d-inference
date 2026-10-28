### Pair-check reservations keep their media

- `darkbloom-cluster-pair-check` hands each worker the whole reservation when it moves the deadline to that worker's clock. It dropped still images and Qwen image/video input, so those qualification requests reached the workers without their media. The owner and peer-link hops re-time reservations with the same field-preserving copy.
