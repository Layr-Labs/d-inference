import DarkbloomClusterPlacement
import Foundation
import Testing

@testable import ProviderCore

/// The GPU wired-memory limits a GLM pair rank's owner may apply with
/// `darkbloom cluster gpu-limit`: bounded by this Mac's memory (macOS keeps
/// 16 GiB), only for validated chips and sizes, and run as fixed commands
/// behind macOS's own administrator prompt. Nothing here runs a command.
@Suite("GLM pair-rank GPU limit approval")
struct GLM5NextWiredLimitApprovalTests {
    private static let plist = "/Library/LaunchDaemons/com.layrlabs.glm53-wired-limits.plist"

    private static let gib: UInt64 = 1 << 30

    @Test("a 128 GB M5 may keep its memory less 16 GiB on the GPU; 256 GB keeps the production values")
    func boundedRecommendations() throws {
        let max128 = try #require(GLM5NextWiredLimit.pairRankRecommendation(chipName: "Apple M5 Max", physicalMemoryBytes: 128 * Self.gib))
        #expect(max128.gpuWiredLimitMB == 114_688 && max128.gpuWiredLimitBytes == 120_259_084_288)
        #expect(max128.userWireLimitBytes == 130_567_005_798)
        #expect(max128.gpuWiredLimitBytes <= (128 << 30) - (16 << 30))
        let ultra = try #require(GLM5NextWiredLimit.pairRankRecommendation(chipName: "Apple M5 Ultra", physicalMemoryBytes: 256 * Self.gib))
        #expect(ultra == GLM5NextWiredLimit.recommendation(chipFamily: .m5, memoryGiB: 256))
        // The single-Mac advice is unchanged: no 128 GB recommendation there.
        #expect(GLM5NextWiredLimit.recommendation(chipFamily: .m5, memoryGiB: 128) == nil)
    }

    @Test("the command raises the limit to exactly the ceiling the planner prices a raise at (ClusterGPUMemoryLimit)")
    func commandValueIsThePlannersCeiling() throws {
        for (chip, memory) in [("Apple M5 Max", UInt64(128)), ("Apple M5 Ultra", 256)] {
            let value = try #require(GLM5NextWiredLimit.pairRankRecommendation(chipName: chip, physicalMemoryBytes: memory * Self.gib))
            #expect(Int(value.gpuWiredLimitMB) == ClusterGPUMemoryLimit.ceilingMegabytes(physicalMemoryBytes: Int(memory * Self.gib)))
        }
    }

    @Test("the command and the plan's advice share one rule: M5 Macs with 128 or 256 GB, read from the chip's own name")
    func eligibility() {
        for (chip, memory) in [("Apple M5 Max", UInt64(128)), ("Apple M5 Ultra", 256), ("Apple M5", 128), ("Apple M5 Pro", 128)] {
            #expect(GLM5NextGPULimitEligibility.applies(chipName: chip, physicalMemoryBytes: memory * Self.gib))
            #expect(GLM5NextWiredLimit.pairRankRecommendation(chipName: chip, physicalMemoryBytes: memory * Self.gib) != nil)
        }
        // Other chips, other sizes, a virtual machine and names no chip class reads.
        for (chip, memory) in [("Apple M4 Max", UInt64(128)), ("Apple M3 Ultra", 256), ("Apple M6 Max", 128), ("Apple M5 Max", 64),
                               ("Apple M5 Max", 96), ("Apple M5 Ultra", 512), ("Apple M5 (Virtual)", 128), ("Apple M55 Max", 128), ("", 128)] {
            #expect(!GLM5NextGPULimitEligibility.applies(chipName: chip, physicalMemoryBytes: memory * Self.gib))
            #expect(GLM5NextWiredLimit.pairRankRecommendation(chipName: chip, physicalMemoryBytes: memory * Self.gib) == nil)
        }
        #expect(GLM5NextGPULimitEligibility.macs == "M5 Macs with 128 or 256 GB")
    }

    @Test("raising runs the sysctl now and installs the boot job key by key, behind one administrator prompt")
    func raiseCommands() throws {
        let value = try #require(GLM5NextWiredLimit.pairRankRecommendation(chipName: "Apple M5 Max", physicalMemoryBytes: 128 * Self.gib))
        let request = try #require(GLM5NextWiredLimitRequest(.raise(value)))
        let assignments = "iogpu.wired_limit_mb=114688 vm.global_user_wire_limit=130567005798 vm.user_wire_limit=130567005798"
        #expect(request.commands == [
            "/bin/launchctl bootout system/com.layrlabs.glm53-wired-limits 2>/dev/null || true",
            "/usr/sbin/sysctl -w " + assignments,
            "/bin/rm -f \(Self.plist)",
            "/usr/bin/plutil -create xml1 \(Self.plist)",
            "/usr/bin/plutil -insert Label -string com.layrlabs.glm53-wired-limits \(Self.plist)",
            "/usr/bin/plutil -insert ProgramArguments -array \(Self.plist)",
            "/usr/bin/plutil -insert ProgramArguments.0 -string /usr/sbin/sysctl \(Self.plist)",
            "/usr/bin/plutil -insert ProgramArguments.1 -string -w \(Self.plist)",
            "/usr/bin/plutil -insert ProgramArguments.2 -string iogpu.wired_limit_mb=114688 \(Self.plist)",
            "/usr/bin/plutil -insert ProgramArguments.3 -string vm.global_user_wire_limit=130567005798 \(Self.plist)",
            "/usr/bin/plutil -insert ProgramArguments.4 -string vm.user_wire_limit=130567005798 \(Self.plist)",
            "/usr/bin/plutil -insert RunAtLoad -bool true \(Self.plist)",
            "/usr/bin/plutil -insert StandardOutPath -string /var/log/com.layrlabs.glm53-wired-limits.log \(Self.plist)",
            "/usr/bin/plutil -insert StandardErrorPath -string /var/log/com.layrlabs.glm53-wired-limits.log \(Self.plist)",
            "/usr/sbin/chown root:wheel \(Self.plist)",
            "/bin/chmod 644 \(Self.plist)",
            "/bin/launchctl bootstrap system \(Self.plist)",
        ])
        #expect(request.shellCommand == request.commands.joined(separator: " && "))
        // In the `&&` line a `|| true` excuses every failure before it: only the first command may carry one.
        #expect(request.commands.dropFirst().allSatisfy { !$0.contains("||") })
        #expect(request.prompt.contains("up to 112 GB of its 128 GB resident, leaving macOS 16 GB"))
        #expect(!request.prompt.contains("GiB"))
        // One AppleScript literal: nothing in it needs escaping.
        #expect(!request.shellCommand.contains("\"") && !request.shellCommand.contains("\\")
            && !request.prompt.contains("\"") && !request.prompt.contains("\\"))
        #expect(request.appleScript == "do shell script \"\(request.shellCommand)\" with prompt \"\(request.prompt)\" with administrator privileges")
        #expect(request.manualCommands.allSatisfy { $0.hasPrefix("sudo /") } && request.manualCommands.count == request.commands.count)
    }

    @Test("undo removes the job and returns the GPU limit to the macOS default, each step on its own")
    func removeCommands() throws {
        let request = try #require(GLM5NextWiredLimitRequest(.remove))
        #expect(request.commands == ["/bin/launchctl bootout system/com.layrlabs.glm53-wired-limits",
                                     "/bin/rm -f \(Self.plist)", "/usr/sbin/sysctl iogpu.wired_limit_mb=0"])
        #expect(request.shellCommand == request.commands.joined(separator: "; "))
        #expect(request.prompt.contains("return this Mac's GPU memory limit to the macOS default"))
    }

    @Test("values that are not the derivation's own are refused")
    func refusesOtherValues() {
        let physical: UInt64 = 128 << 30
        let above = GLM5NextWiredLimit.Recommendation(memoryGiB: 128, gpuWiredLimitMB: physical >> 20,
            userWireLimitBytes: physical * 95 / 100)
        let wire = GLM5NextWiredLimit.Recommendation(memoryGiB: 128, gpuWiredLimitMB: 114_688, userWireLimitBytes: physical)
        let size = GLM5NextWiredLimit.Recommendation(memoryGiB: 64, gpuWiredLimitMB: (physical / 2 - (16 << 30)) >> 20,
            userWireLimitBytes: physical / 2 * 95 / 100)
        #expect(GLM5NextWiredLimitRequest(.raise(above)) == nil)
        #expect(GLM5NextWiredLimitRequest(.raise(wire)) == nil)
        #expect(GLM5NextWiredLimitRequest(.raise(size)) == nil)
    }
}
