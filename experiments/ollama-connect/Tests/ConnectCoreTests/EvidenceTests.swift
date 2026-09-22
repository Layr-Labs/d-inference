import Foundation
import Testing
@testable import ConnectCore

private let now: Double = 1_800_000_000

private func snapshot(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> WorkerSnapshot {
    var object: [String: Any] = [
        "schema": 1, "pid": 42, "process_identity": ["pid": 42, "start_time_micros": 1_799_999_900_000_000],
        "written_at": now - 1, "started_at": now - 100,
        "coordinator_url": "wss://api.darkbloom.dev/ws/provider", "attestation_public_key": "expected-key",
        "warm_models": ["approved-model"], "advertised_models": ["approved-model"], "version": "test",
        "stats": ["requests_served": 0, "tokens_generated": 0],
        "trust": ["status": "online", "received_at": now - 1,
                  "authorization": ["protocol": 1, "path": "app_attest", "expires_at": now + 30,
                                    "session_id": "expected-session", "machine_id": "expected-machine"]]
    ]
    change(&object)
    return try JSONDecoder().decode(WorkerSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

private func remote(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> NetworkAttestation {
    var object: [String: Any] = ["provider_id": "expected-session", "se_public_key": "expected-key", "status": "online", "app_attest_authorized": true, "authorization_expires_at": now + 20, "models": ["approved-model"]]
    change(&object)
    return try JSONDecoder().decode(NetworkAttestation.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func currentNetworkAndSignedProcessMustAgree() throws {
    let evidence = ServingEvidence.evaluate(snapshot: try snapshot(), processVerified: true, remote: [try remote()], fetchedAt: now, now: now)
    #expect(evidence.confirmed)
    #expect(evidence.isCurrent(at: now + 8))
    #expect(!evidence.isCurrent(at: now + 9)) // local evidence is the shortest lifetime
    #expect(!evidence.isCurrent(at: .nan))
}

@Test(arguments: ["unsigned", "missing", "staleRemote", "futureRemote", "revoked", "expired", "wrongSession", "wrongKey", "offline", "duplicates"])
func networkEvidenceCannotBeSubstituted(attack: String) throws {
    let record = try remote { value in
        switch attack {
        case "revoked": value["app_attest_authorized"] = false
        case "expired": value["authorization_expires_at"] = now
        case "wrongSession": value["provider_id"] = "other"
        case "wrongKey": value["se_public_key"] = "other"
        case "offline": value["status"] = "offline"
        default: break
        }
    }
    let fetchedAt = attack == "staleRemote" ? now - 11 : attack == "futureRemote" ? now + 3 : now
    let records = attack == "missing" ? [] : attack == "duplicates" ? [record, record] : [record]
    #expect(!ServingEvidence.evaluate(snapshot: try snapshot(), processVerified: attack != "unsigned", remote: records, fetchedAt: fetchedAt, now: now).confirmed)
}

@Test(arguments: ["staleFile", "futureFile", "wrongPID", "unknownSchema", "wrongCoordinator", "expired", "staleDecision", "beforeStart", "unknownProtocol", "legacy", "noSession", "offline"])
func localEvidenceCannotGrantPermission(attack: String) throws {
    let local = try snapshot { value in
        var trust = value["trust"] as! [String: Any]
        var auth = trust["authorization"] as! [String: Any]
        switch attack {
        case "staleFile": value["written_at"] = now - 11
        case "futureFile": value["written_at"] = now + 3
        case "wrongPID": value["pid"] = 43
        case "unknownSchema": value["schema"] = 2
        case "wrongCoordinator": value["coordinator_url"] = "wss://attacker.invalid/ws/provider"
        case "expired": auth["expires_at"] = now
        case "staleDecision": trust["received_at"] = now - 11
        case "beforeStart": value["started_at"] = now
        case "unknownProtocol": auth["protocol"] = 2
        case "legacy": auth["path"] = "legacy"
        case "noSession": auth["session_id"] = ""
        case "offline": trust["status"] = "offline"
        default: break
        }
        trust["authorization"] = auth
        value["trust"] = trust
    }
    #expect(!ServingEvidence.evaluate(snapshot: local, processVerified: true, remote: [try remote()], fetchedAt: now, now: now).confirmed)
}

@Test func localStatusAloneNeverConfirms() throws {
    #expect(!ServingEvidence.evaluate(snapshot: try snapshot(), processVerified: true, remote: [], fetchedAt: now, now: now).confirmed)
}

@Test func busyAuthorizedProviderRemainsConfirmed() throws {
    let busy = try remote { $0["status"] = "serving" }
    #expect(ServingEvidence.evaluate(snapshot: try snapshot(), processVerified: true, remote: [busy], fetchedAt: now, now: now).confirmed)
}
