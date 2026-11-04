### `darkbloom cluster` on Macs paired before: next steps, Pair again and Start over

- A Mac whose saved pairing was made with another Secure Enclave key (after
  moving between the Darkbloom and DevNet apps, or after the installer made a
  new key) now says so when `darkbloom cluster` opens and offers **Pair again**,
  instead of its usual menu while every start of its part failed with "pair
  again".
- When the other Mac does not answer over the cable, the Mac that follows offers
  **Try again**, **Pair again** and **Quit**, and the leader adds **Pair again**
  to its list. This ends the case where one Mac waited at "2/4 Pair" while the
  other, still holding an earlier pairing, showed its status and ended.
- Choosing a model no longer spins on "Reading both Macs over the cable" with no
  reason: the screen says why it is still waiting and, on a Mac paired before,
  ends with **Try again**, **Pair again** and **Quit**.
- The Mac that follows names the Mac it follows and the command to run there
  ("This Mac follows the other Mac (Apple M3 Ultra, 256 GB): to choose or change
  the model, run `darkbloom cluster` on that Mac.") instead of "Nothing to do
  here".
- Setting up a cable port from `darkbloom cluster` continues to the Mac's usual
  screen instead of ending there.
- Every paired Mac offers **Start over (pair again)**, which asks once (No by
  default). It and **Pair again** unpair this Mac exactly as `darkbloom cluster
  pair --forget` does, then run the ordinary pairing with the code on both
  screens.
