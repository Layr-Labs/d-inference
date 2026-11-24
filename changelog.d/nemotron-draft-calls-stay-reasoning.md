### Nemotron 3.5 Lightning no longer repeats parallel tool calls

- With reasoning on, Lightning sometimes closes its thought early to sketch the
  calls it plans, keeps reasoning, closes the thought a second time and then
  writes the real calls. The sketched calls were returned as well, so a
  request for two parallel calls got four. Tool calls written before that
  second close now stay in the reasoning, and only the final calls are
  returned.
- When reasoning is on, Lightning's tool calls (and any text after them) now
  reach a streaming client when generation ends, not while they are written.
