import Foundation

private func require(_ value: @autoclosure () -> Bool) { precondition(value()) }
private func refuses(_ body: () throws -> Void) {
    do { try body(); preconditionFailure("Expected refusal") } catch {}
}

@main private struct TimingChecks {
    static func main() throws {
        var rows: [Gemma4RemoteMTPWindowTiming] = []
        for index in 0..<127 {
            try Gemma4RemoteMTPTiming.append(.init(ordinal:index,kind:.verification,width:1,accepted:0),
                to:&rows,outputCount:128)
        }
        require(rows.count == 127)
        refuses { try Gemma4RemoteMTPTiming.append(.init(ordinal:127,kind:.tail,width:1,accepted:0),to:&rows,outputCount:128) }
        require(rows.count == 127)
        print("PASS window-count-bounded-by-output")

        var empty: [Gemma4RemoteMTPWindowTiming] = []
        refuses { try Gemma4RemoteMTPTiming.append(.init(ordinal:1,kind:.prime,width:1,accepted:0),to:&empty,outputCount:16) }
        refuses { try Gemma4RemoteMTPTiming.append(.init(ordinal:0,kind:.verification,width:4,accepted:0),to:&empty,outputCount:16) }
        refuses { try Gemma4RemoteMTPTiming.append(.init(ordinal:0,kind:.verification,width:3,accepted:3),to:&empty,outputCount:16) }
        require(empty.isEmpty)
        print("PASS ordinal-width-prefix-refusals")

        refuses { try Gemma4RemoteMTPTiming.append(.init(ordinal:0,kind:.tail,width:2,accepted:0),to:&empty,outputCount:16) }
        refuses { try Gemma4RemoteMTPTiming.append(.init(ordinal:0,kind:.prime,width:1,accepted:0),to:&empty,outputCount:129) }
        try Gemma4RemoteMTPTiming.append(.init(ordinal:0,kind:.prime,width:1,accepted:0),to:&empty,outputCount:2)
        require(empty.count == 1)
        print("PASS seed-tail-and-envelope-bounds")

        let counts = Gemma4MTPControlCounters()
        let before = try counts.snapshot()
        for direction in [Gemma4MTPControlCounters.Direction.send,.receive] {
            try counts.begin(direction); try counts.resourceChecked(); try counts.innerChecked()
            try counts.resourceChecked(); try counts.complete()
        }
        let after = try counts.snapshot()
        let delta = try Gemma4RemoteMTPControlDelta(before:before,after:after)
        require(delta.sends == 1 && delta.receives == 1 && delta.completedOperations == 2)
        require(delta.entryResourceChecks == 2 && delta.exitResourceChecks == 2 && delta.innerLifetimeChecks == 2)
        print("PASS exact-request-control-delta")
        refuses { _ = try Gemma4RemoteMTPControlDelta(before:after,after:before) }
        print("PASS counter-regression-refused")

        require(MemoryLayout<Gemma4RemoteMTPWindowTiming>.stride * 128 <= 32*1024)
        print("PASS fixed-window-storage-below-32-kib")

        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let ordinaryRow = try encoder.encode(rows[0])
        var worst = try JSONSerialization.jsonObject(with:ordinaryRow) as! [String:Any]
        for key in Array(worst.keys) where key.hasSuffix("Nanoseconds") { worst[key] = UInt64.max }
        let worstRow = try JSONSerialization.data(withJSONObject:worst,options:[.sortedKeys])
        require(worstRow.count <= 2048)
        let report = Gemma4RemoteMTPRequestTiming(windows:rows,finalFinishNanoseconds:0,controlDelta:delta)
        let data = try encoder.encode(report)
        let object = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        require(data.count <= 128*2048 + 4096)
        require(object["schema"] as? String == "gemma4_remote_mtp_target_window_timings_v1")
        require(object["assistantGPUTimeMeasured"] as? Bool == false)
        require(object["requestControlExcludesCohortBarriers"] as? Bool == true)
        print("PASS bounded-encoding-and-clock-meaning")
    }
}
