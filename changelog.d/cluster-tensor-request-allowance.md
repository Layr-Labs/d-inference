### Price complete tensor-parallel request reservations

Tensor-parallel families can now supply their native request reservation to the
planner, including allocator-bounded authenticated collective frames and selected-expert
frame sizes. Placement keeps the larger complete estimate without charging KV
state twice and refuses requests beyond a quoted envelope. Existing families
without this allowance retain their previous planning behavior.
