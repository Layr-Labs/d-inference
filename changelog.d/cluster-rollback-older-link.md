### Two-Mac pairs: a rollback to a release before 0.10.13 no longer gets the pair's link key back

- Releases before 0.10.13 link the two Macs with an older handshake. A rollback to one of them used to write each pairing's link key back to a file so that release could link again. The updater now writes no key for such a release, so a pair never links with the older handshake again. The keys stay in the Keychain, and the pair links again once both Macs run 0.10.13 or later. Rollbacks to 0.10.13 or later are unchanged.
