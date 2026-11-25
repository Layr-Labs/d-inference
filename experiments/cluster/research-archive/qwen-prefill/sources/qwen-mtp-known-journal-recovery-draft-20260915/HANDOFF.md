# Explicit recovery of the two known MTP journals

This private maintenance command only admits the two exact 333-byte journals captured from MTP `physical-1`. The failed controller reported actual native cleanup on both ranks but no owner release ACK on either. The parent observed no remaining native processes and retained the nonempty journals. Administrative clearing does not turn that run into a pass, manufacture an ACK or establish numerical/MTP generation qualification.

The fixed canonical file is `/Users/developer/.darkbloom/cluster-device/native-device.lease`. No command-line option changes it. The command must run as its owning user, without sudo. It requires explicit rank, peer, cluster, epoch, journal hash, failed-controller hash and the administrative-confirmation flag. The full journal schema, lease ID, owner incarnation and native launch ID are checked against the exact known case. Empty, changed, arbitrary or unknown records are refused.

`evidence/` contains exact mode-0600 copies of the two captured journals, failed controller JSONL and parent execution record. Embedded hashes and content checks require the known failed run, matching configuration/epoch/request, actual native-cleanup flags, missing release ACKs, reaped local controller group and captured per-rank journal/process observations. These are retained historical observations, not a live cleanup certificate. They are not sufficient without the fresh checks below.

The command opens every canonical directory component without following links, then opens the existing lease without creating it. It requires the current user, mode0700 directory, mode0600 regular single-link file, stable device/inode and a nonblocking exclusive flock. It takes two fresh bounded `/bin/ps` samples under that same lock, refusing installed/private `darkbloom*`, `qwen*`, `cluster-inference` and `owner-controller` processes. The lock prevents cooperating owners or solo callers from acquiring the device during recovery. Process absence alone never authorizes clearing. This maintenance assumes the reviewed installed/private executable names and canonical gate; it does not discover arbitrary renamed unmanaged GPU programs.

Before clearing, it creates a fresh mode0700 `administrative-recovery-LEASE-UUID` directory inside the canonical directory. It writes the exact original journal, exact failed-run evidence, authorization record and both process observations as exclusive mode0600 files. Every file and both directories are fsynced; file identities and bytes are rechecked. The canonical path, device/inode, permissions and exact bytes are rechecked immediately before `ftruncate` on the same locked file descriptor. It then fsyncs that descriptor, reads back empty bytes on the same inode, and retains a durable administrative result. It never renames, deletes or recreates the canonical file.

No pre-existing process, owner, worker or process group is signalled. Only the command's own newly launched read-only `/bin/ps` observer is terminated if its three-second observation bound fails. An operation deadline is checked before clearing; a 30-second alarm also remains armed through final stdout publication. Any unknown observation, held lock, missing evidence, changed record/path, backup failure or active process refuses recovery. If truncation was attempted but a later sync/receipt fails, retain the exact backup and failure receipt for manual inspection; the command never restores or retries automatically.

Root owns deployment and execution after source review. Copy the four runtime modules and `evidence/` into a fresh private directory, preserving evidence directory mode0700 and file mode0600, then verify this source manifest. The proposed directory is `/Users/developer/DarkbloomDev/known-mtp-journal-recovery-20260915`; `commands.json` contains the exact per-rank argv. Retain stdout, stderr, exit status, the backup directory and a separate post-command canonical stat/readback. Do not run through doctor/start or as automatic repair.

On the 24GB host:

```sh
/usr/bin/python3 -B /Users/developer/DarkbloomDev/known-mtp-journal-recovery-20260915/recover_known_mtp_journal.py --rank 0 --peer darkbloom-24 --cluster-id qwen9b-single-mtp-proposal --epoch 6a5c1ca9-076f-4392-85fa-a7fbf33c3f68 --journal-sha256 a733ffea03efc48b822514376b05705f5309cc10159166340185a1d10684c108 --controller-sha256 a628f325c1c26f86827034407df4196190dbc1364f16e07ca03eb0088f39a17c --confirm-administrative-recovery
```

On the 48GB host:

```sh
/usr/bin/python3 -B /Users/developer/DarkbloomDev/known-mtp-journal-recovery-20260915/recover_known_mtp_journal.py --rank 1 --peer darkbloom-48 --cluster-id qwen9b-single-mtp-proposal --epoch 6a5c1ca9-076f-4392-85fa-a7fbf33c3f68 --journal-sha256 1d94001e59188d44d8e420470037ed79075249f23d1219f280bf41ca5ca8a1a4 --controller-sha256 a628f325c1c26f86827034407df4196190dbc1364f16e07ca03eb0088f39a17c --confirm-administrative-recovery
```

`checks-2` passes ten groups under `/usr/bin/python3`: same-inode success/retained exact backups, both known cases, missing/altered cleanup evidence, changed journal/held lock, mode/owner/hardlink/symlink refusals, late bytes/path replacement, backup fsync/tampering, deadline/interruption/active process refusal, actual executable-family parser coverage, and a real local kernel process observation. No canonical user lease or remote host was accessed by tests. The real-child case uses the unmodified signed `/bin/sleep` with a test-only name-set extension; production names are tested separately. `checks-1` preserves an initial fixture failure: the copied sleep executable was observed already terminated with signal9 before the process sample, so only the fixture was corrected. No inference/model/native worker was run.

```sh
/usr/bin/python3 -B -m unittest -v test_recovery
```

Independent source review is recorded separately; the original failed physical run and its artifacts remain unchanged.
