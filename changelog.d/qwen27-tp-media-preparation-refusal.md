### Qwen 3.8 27B pair media: preparation on its own stream, refused alone

- A Qwen 3.8 27B tensor-parallel pair no longer ends both workers when rank 0's
  media preparation fails. Rank 0 prepares a request's image or video patches at
  admission, on a CPU stream of its own while its executor waits, so another
  thread's failed CPU work can no longer fail the preparation (after the main
  merge, MLX overlaps evaluations across threads and hands a stream's stored
  error to whichever caller synchronizes it next; the pair's media requests
  failed this way after a dozen had passed). A preparation that does not
  reproduce the leader's patches refuses that request alone with a retryable
  error and its reason in the worker log, and the pair keeps serving. A vision
  tower failure still ends the workers.
