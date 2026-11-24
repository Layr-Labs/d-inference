### Prompt preparation counts against the serving width

- A text request now holds its share of the whole-Mac serving allowance from
  before its prompt is rendered and tokenized, not only from submission. A full
  Mac refuses a request as capacity before preparing its prompt, and prompts
  being prepared at the same time count against the serving width. The share
  becomes the request's serving allowance at submission, so an admitted
  request cannot lose its place between preparation and submission. The
  owner's local requests still wait for room at submission.
