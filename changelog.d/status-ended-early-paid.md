### `darkbloom status` says which requests that ended early are paid

- The line under `Requests served` said that every request that ended early "may be unpaid". Many are paid: when the requester leaves mid-answer, the coordinator pays for the prompt and the output your Mac had already sent. `status` now lists those requests by what stopped them and whether they are paid, for example:
  ```
    7 of them ended early:
      5 paid for the work done: the requester left mid-answer
      1 unpaid: another Mac answered first
      1 unpaid: this Mac lost its connection
  ```
  Your Mac knows itself when its connection dropped or when it stopped a request (a drain or an add-on hold). The other causes come with the coordinator's cancel from the coordinator update that sends them; until then those requests share one note: paid for the work done if the requester left mid-answer, unpaid if another Mac answered first or this Mac started too late.
- A request whose answer had already finished when the requester left is no longer counted as ended early: it went out whole and is paid in full. About 1 in 100 of the requests counted before were such answers.
- The count now takes a line per cause, so a script that reads `status` line by line sees more lines.
