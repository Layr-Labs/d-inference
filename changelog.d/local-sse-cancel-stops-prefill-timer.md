### Local streamed response stops at once when its write ends

- When the write of a streamed local response ends early (a cancelled task or
  a closed connection while a frame is written), the prefill progress timer and
  the task that reads the engine's frames now stop at once. Before, they ran
  until the server freed the response.
