extension WholeMacServiceBudget {
    /// The coordinator needs every slot's work to establish whole-Mac
    /// quiescence, but only when some bridge owns reviewed timing evidence.
    /// A bridge's work field signals its retained profile, independently of
    /// the profile reference that posture can temporarily withdraw.
    func capacitySnapshot(slots: [BackendSlotCapacity]) -> Snapshot {
        guard slots.contains(where: { $0.deadlineWork != nil }) else {
            return snapshot()
        }
        let epochs = Dictionary(slots.compactMap { slot in
            slot.performanceMeasurements.map { (slot.model, $0.epoch) }
        }, uniquingKeysWith: { _, latest in latest })
        let profiles = Dictionary(slots.compactMap { slot in
            slot.deadlineProfile.map { (slot.model, $0.id) }
        }, uniquingKeysWith: { _, latest in latest })
        return snapshot(slotEpochs: epochs, profileIDs: profiles)
    }
}
