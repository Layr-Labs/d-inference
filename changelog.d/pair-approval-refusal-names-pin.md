### A refused pair approval says which pin differs

When a Mac refuses a cluster approval because its saved setup no longer
matches, `darkbloom cluster` now names each pin that differs (model, Plan,
artifact, runtime, capability, profile or schedule), with the approval's and the
setup's values. Before, it said only "Saved pair approval differs from the
model, runtime, Plan, profile or schedule". The leader keeps the refused
approval in its setup record (`approvalRefused`) beside the note, so it can be
compared with the next one. The other Mac clears a refusal note it recorded
while it led once it saves the leader's approval, so its status no longer shows
an old refusal after the pair is approved again.
