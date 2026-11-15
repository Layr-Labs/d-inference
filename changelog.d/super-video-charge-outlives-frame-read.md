### A cancelled Nemotron Super video keeps its memory charge until its frame read returns

- Cancelling a Nemotron Super video request, as a coordinator cancel or
  draining the model does, or failing it mid-decode returned its ingress and
  media memory charges as soon as the request unwound, while the frame read
  its pull gave up on could still be decoding on the reader's queue. For up to
  one frame decode the shared memory ledger counted less than was in use, and
  another request could be admitted into that memory. The charges now return
  only after that read and the reader's cancellation have run. The request's
  cleanup, and so draining, waits for them at most 1 s; a read still decoding
  after that returns the charges itself when it ends.
