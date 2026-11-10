### `darkbloom status` says which requests that ended early are paid

- The line under `Requests served` said that every request that ended early "may be unpaid". Many are paid: when the requester leaves mid-answer, the coordinator pays for the prompt and the output your Mac had already sent. The note now says which are paid and which are not, for example: "1 of them ended early: paid for the work done if the requester left mid-answer, unpaid if another Mac answered first, this Mac started too late or lost its connection."
- The count is unchanged. The note now takes two lines, so a script that reads `status` line by line sees one more.
