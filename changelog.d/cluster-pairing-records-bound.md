### Two-Mac pairs: a pairing record changed outside Darkbloom is no longer trusted

- Each pairing's record in `pairings.json` is now kept in this Mac's Keychain too, beside the pair's link key. A record changed by anything other than Darkbloom no longer gets the link key: the pair does not link, and its error says to pair the Macs again. A key file put beside the records is no longer taken in once the store has been updated.
- Existing pairs keep working: the first read after the update keeps their records. A rollback to an earlier release still links. While the Mac is locked after its first unlock, the pair keeps serving as before.
