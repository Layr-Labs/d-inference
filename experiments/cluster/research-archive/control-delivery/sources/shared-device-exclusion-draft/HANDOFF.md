# Shared native device exclusion

Promote the two proposed files together. `ClusterDeviceExclusion(directoryURL:)` in Process is the public solo gate. Supply `ClusterUserPaths().deviceDirectory`, acquire before model/MLX startup in the actual foreground/local serving process, and retain through actual engine teardown. Daemon-launching and cluster leader parents must not acquire it; their actual owner children acquire the same canonical gate.

Remote keeps a thin typed journal wrapper using the OwnerService SPI. Existing service cleanup/release guards remain unchanged. Construction never truncates unknown journals; only this live gate’s successfully recorded and unchanged journal can resolve. The final configured-directory identity and empty-file checks also protect solo construction. No recovery API exists. Advisory filesystem locking assumes cooperating same-user processes; it does not constrain malicious same-user mutation after admission.

Ten focused actual-file/CPU-child groups passed with Swift 6 warnings-as-errors and empty stderr. The final two groups inject directory replacement and late same-inode journal insertion at the internal pre-validation seam. No model/native/network work. Earlier eight/nine-group receipts remain in the parent draft. Full Remote/service and Provider integration remain root-owned.

Configuration saves contend on this same gate. Saving alongside a newly gate-owning solo process can now refuse busy; the earlier old-solo inert-save behavior is not a future mode guarantee.
