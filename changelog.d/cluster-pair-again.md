### `darkbloom cluster` offers Pair again for a pairing it cannot use

- A Mac whose saved pairing was made with another Secure Enclave key (after
  moving between the Darkbloom and DevNet apps, or after the installer made a
  new key) now says so when `darkbloom cluster` opens and offers **Pair again**,
  instead of its usual menu while every start of its part failed with "pair
  again".
- When the other Mac does not answer over the cable, the Mac that follows offers
  **Try again**, **Pair again** and **Quit** instead of "Nothing to do here",
  and the leader adds **Pair again** to its list. This ends the case where one
  Mac waited at "2/4 Pair" while the other, still holding an earlier pairing,
  showed its status and ended.
- **Pair again** unpairs this Mac exactly as `darkbloom cluster pair --forget`
  does, then runs the ordinary pairing with the code on both screens; the
  other Mac offers the same item when it still holds the old pairing.
