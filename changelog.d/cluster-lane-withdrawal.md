### Independent cluster lane withdrawal

Fixed cluster batch cancellation so withdrawing an admitted request that has
not started retires that request without interrupting another request waiting
for token credit. Accepting a start command closes the withdrawal window, and
duplicate cancellation messages share the pending retirement acknowledgment.
