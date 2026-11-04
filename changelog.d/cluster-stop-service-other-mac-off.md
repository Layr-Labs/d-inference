### `darkbloom cluster stop --service` works when the other Mac is already off

- On the Mac that leads, `darkbloom cluster stop --service` failed (exit 1) when the other Mac's cluster service was
  already off or did not answer, and left this Mac's cluster service and login agent running; only
  `--local-only` finished it.
- Once this Mac has stopped serving, its cluster service now stops and leaves login anyway, and the command says what
  happened on each Mac: `This Mac stopped serving.`, then that the other Mac did not answer and was not asked to stop
  (its cluster service may already be off), and to run `darkbloom cluster stop --service` there too if it is still on.
- When this Mac's own part has not finished releasing its memory, the command still fails and keeps the service, as
  before.
