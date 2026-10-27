import Cmlx
import Foundation
import MLX

extension Collective {
    /// The immutable load deadline bounds startup independently of renewable
    /// short process leases. This budget cannot be used again for requests.
    func beginStartupWaitBudget(deadlineUptimeNanoseconds: UInt64) throws {
        guard transport == .jaccl else {
            throw ProbeError("Native startup wait budget requires JACCL")
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineUptimeNanoseconds > now else {
            throw ProbeError("Native startup wait deadline has expired")
        }
        // Floor avoids rounding up the remaining duration. Core starts its
        // relative clock later, so the existing independent hard startup timer
        // remains authoritative across bridge/scheduling overhead.
        let milliseconds = min(UInt64(900_000), (deadlineUptimeNanoseconds - now) / 1_000_000)
        guard milliseconds > 0 else { throw ProbeError("Native startup wait deadline is too near") }
        try MLX.withError { error in
            let status = mlx_distributed_group_begin_startup_wait_budget(handle, Int64(milliseconds))
            try error.check()
            guard status == 0 else { throw ProbeError("Native startup wait budget refused") }
        }
    }

    func endStartupWaitBudget() throws {
        guard transport == .jaccl else {
            throw ProbeError("Native startup wait budget requires JACCL")
        }
        try MLX.withError { error in
            let status = mlx_distributed_group_end_startup_wait_budget(handle)
            try error.check()
            guard status == 0 else { throw ProbeError("Native startup wait completion refused") }
        }
    }
}
