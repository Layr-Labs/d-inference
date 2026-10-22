import CryptoKit
import DarkbloomClusterProtocol
import Foundation
import XCTest
@testable import DarkbloomClusterWorker
@testable import DarkbloomClusterRuntime

/// CPU argument parsing only. No runtime construction, capacity or serving proof.
final class MiMoImageStartupBindingTests:XCTestCase {
    func arguments() throws -> [String] {
        let executable = try XCTUnwrap(Bundle.main.executableURL)
        let digest = SHA256.hash(data:try Data(contentsOf:executable)).map { String(format:"%02x",$0) }.joined()
        return ["--model-dir","/cpu-fixture/metadata-only","--rank","0","--stage-cut","24",
            "--membership-epoch",UUID().uuidString.lowercased(),"--model-id",ClusterMiMoImageCandidate.runtimeModelID,
            "--artifact-sha256",ClusterMiMoImageCandidate.artifactSHA256,
            "--configuration-sha256",ClusterMiMoImageCandidate.configurationSHA256,
            "--peer0-id","cpu-fixture-0","--peer0-build-sha256",digest,
            "--peer1-id","cpu-fixture-1","--peer1-build-sha256",digest,
            "--deadline-uptime-nanoseconds","120000000100",
            "--runtime-profile",ClusterMiMoImageCandidate.profileID,"--qualification-switches","yes",
            "--data-plane","encrypted_v1","--startup-deadline-uptime-nanoseconds","120000000100"]
    }
    func testExplicitPrivateProfileBindsLaunchAndPipelineMTPWithoutLoading() throws {
        let args = try arguments()
        let value = try WorkerConfiguration(arguments:args,now:100)
        XCTAssertEqual(value.load.runtimeProfile,ClusterMiMoImageCandidate.profileID)
        XCTAssertTrue(value.qualificationSwitchesPermitted && value.dataPlaneEncrypted)
        XCTAssertNotNil(value.startupDeadlineUptimeNanoseconds)
        let mtp = try WorkerConfiguration(arguments:args+["--generation-mode",ClusterGenerationMode.pipelineMTP.rawValue,"--mtp-depth","3"],now:100)
        XCTAssertEqual(mtp.load.runtimeProfile,value.load.runtimeProfile)
        let text = stride(from:0,to:args.count,by:2).filter { !["--runtime-profile","--qualification-switches"].contains(args[$0]) }
            .flatMap { [args[$0],args[$0+1]] }
        XCTAssertNil(try WorkerConfiguration(arguments:text,now:100).load.runtimeProfile)
    }
    func testCrossedModelProfileUnqualifiedOrUnencryptedLaunchRefuses() throws {
        let args = try arguments()
        for name in ["--runtime-profile","--model-id","--artifact-sha256","--configuration-sha256"] {
            var changed=args;let i=try XCTUnwrap(changed.firstIndex(of:name));changed[i+1]="unknown"
            XCTAssertThrowsError(try WorkerConfiguration(arguments:changed,now:100))
        }
        for name in ["--qualification-switches","--data-plane","--startup-deadline-uptime-nanoseconds"] {
            let changed=stride(from:0,to:args.count,by:2).filter { args[$0] != name }.flatMap { [args[$0],args[$0+1]] }
            XCTAssertThrowsError(try WorkerConfiguration(arguments:changed,now:100))
        }
        XCTAssertThrowsError(try WorkerConfiguration(arguments:args+["--runtime-profile",ClusterMiMoImageCandidate.profileID],now:100))
        XCTAssertThrowsError(try WorkerConfiguration(arguments:args+["--generation-mode",ClusterGenerationMode.phaseSplit.rawValue],now:100))
        XCTAssertThrowsError(try WorkerConfiguration(arguments:args+["--evidence-directory","/cpu-fixture/recording"],now:100))
    }
    func testFixedStartupDeadlineIsSeparateFromRenewableFirstLease() throws {
        var args = try arguments()
        let now: UInt64 = 100
        let firstLease = now + 20_000_000_000
        let startup = now + 900_000_000_000
        args[try XCTUnwrap(args.firstIndex(of: "--deadline-uptime-nanoseconds")) + 1] = String(firstLease)
        args[try XCTUnwrap(args.firstIndex(of: "--startup-deadline-uptime-nanoseconds")) + 1] = String(startup)
        let value = try WorkerConfiguration(arguments: args, now: now)
        XCTAssertEqual(value.load.deadlineUptimeNanoseconds, firstLease)
        XCTAssertEqual(value.load.startupDeadlineUptimeNanoseconds, startup)
        XCTAssertEqual(try value.load.startupWaitDeadline(now: now), startup)
        let lease = try XCTUnwrap(value.load.lease)
        lease.renew(now: now + 90_000_000_000, ttl: 20_000_000_000)
        XCTAssertEqual(value.load.currentDeadlineUptimeNanoseconds, now + 110_000_000_000)
        XCTAssertEqual(try value.load.startupWaitDeadline(now: now + 90_000_000_000), startup)
        XCTAssertThrowsError(try value.load.startupWaitDeadline(now: startup))
        func configuration(leased: Bool, explicit: UInt64?) -> QwenResidentLoadConfiguration {
            .init(identity: value.load.identity, modelDirectory: value.load.modelDirectory,
                  rank: value.load.rank, stageCut: value.load.stageCut,
                  deadlineUptimeNanoseconds: firstLease,
                  lease: leased ? lease : nil, startupDeadlineUptimeNanoseconds: explicit)
        }
        XCTAssertThrowsError(try configuration(leased: true, explicit: nil).startupWaitDeadline(now: now))
        XCTAssertThrowsError(try configuration(leased: true, explicit: UInt64.max).startupWaitDeadline(now: now))
        XCTAssertEqual(try configuration(leased: false, explicit: nil).startupWaitDeadline(now: now), firstLease)
        XCTAssertEqual(try configuration(leased: false, explicit: startup).startupWaitDeadline(now: now), firstLease)
        XCTAssertThrowsError(try configuration(leased: false, explicit: nil).startupWaitDeadline(now: firstLease))
    }

}
