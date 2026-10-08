import Foundation

private enum Refusal: Error { case owner, entry, exit }
private func require(_ condition: @autoclosure () -> Bool) { precondition(condition()) }
private func refuses(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected refusal") } catch {}
}

@main private struct ControlCounterChecks {
    static func main() throws {
        let counters = Gemma4MTPControlCounters()
        try counters.begin(.send)
        var observations = 0
        try BoundedControlResourceOperation().send(resourceCheck:{
            observations += 1; try counters.resourceChecked()
        },faultCheck:{ try counters.innerChecked() }) { checkpoint in
            let bytes = Data(repeating:7,count:16_384)
            try checkpoint.check(); try checkpoint.check()
            require(bytes.count == 16_384 && observations == 1)
        }
        try counters.complete()
        let first = try counters.snapshot()
        require(first.sends == 1 && first.receives == 0 && first.completedOperations == 1)
        require(first.entryResourceChecks == 1 && first.exitResourceChecks == 1 && first.innerLifetimeChecks == 2)
        print("PASS fixed-frame-two-fresh-boundaries-counted")

        try counters.begin(.receive)
        let copied = try BoundedControlResourceOperation().receive(resourceCheck:{ try counters.resourceChecked() },
            faultCheck:{ try counters.innerChecked() }) { checkpoint in
            try checkpoint.check(); return Data(repeating:9,count:16_384)
        }
        try counters.complete(); let both = try counters.snapshot()
        require(copied.count == 16_384 && both.sends == 1 && both.receives == 1 && both.completedOperations == 2)
        require(both.entryResourceChecks == 2 && both.exitResourceChecks == 2 && both.innerLifetimeChecks == 3)
        print("PASS shared-send-receive-chronology")

        let innerBeforeEntry = Gemma4MTPControlCounters(); try innerBeforeEntry.begin(.send)
        refuses { try innerBeforeEntry.innerChecked() }; refuses { _ = try innerBeforeEntry.snapshot() }
        print("PASS inner-before-entry-poisons")

        let early = Gemma4MTPControlCounters(); try early.begin(.receive); try early.resourceChecked()
        refuses { try early.complete() }; refuses { _ = try early.snapshot() }
        print("PASS completion-without-exit-refused")

        let reentry = Gemma4MTPControlCounters(); try reentry.begin(.send)
        refuses { try reentry.begin(.receive) }; refuses { try reentry.resourceChecked() }
        print("PASS shared-operation-reentry-poisons")

        let failed = Gemma4MTPControlCounters(); try failed.begin(.receive)
        var published: Data?
        do {
            published = try BoundedControlResourceOperation().receive(resourceCheck:{ try failed.resourceChecked() },
                faultCheck:{ throw Refusal.owner }) { checkpoint in
                try checkpoint.check(); return Data(repeating:0,count:16_384)
            }
            preconditionFailure("Failed owner published a control")
        } catch { failed.poison() }
        require(published == nil); refuses { _ = try failed.snapshot() }; refuses { try failed.begin(.send) }
        print("PASS owner-failure-prevents-publication-and-reuse")
    }
}
