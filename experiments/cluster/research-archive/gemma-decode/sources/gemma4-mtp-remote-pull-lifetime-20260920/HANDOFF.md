# Pull capture lifetime correction

Preserve core38cee. This sole source replacement stores the actual target capture before the first payload send, keeps an explicit extended lifetime through the complete seeded response, and clears only after exact response validation. Any send, fence, scope or ACK failure retains the capture in the failed target adapter. Successful original session cancellation/retirement may clear it; a failed cancellation leaves it retained. The original native owner must retain this adapter through its failure fence or process retirement. No reset, resource discount, transport, deadline or acceptance changes.

Source-only; no compiler, fixture or native execution. Native qualification must inject send/fence/seeded-response failure and verify the stored source capture remains live until successful original cancellation or parent-owned process retirement. The existing five receive/shape/prefix controls are not lifetime proof for this path.
