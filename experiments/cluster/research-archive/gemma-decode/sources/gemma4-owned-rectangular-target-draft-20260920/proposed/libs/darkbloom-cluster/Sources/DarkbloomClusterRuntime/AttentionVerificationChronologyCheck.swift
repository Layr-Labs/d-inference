#if CBV2_WINDOW_STATE_FIXTURE
import Foundation
import MLX
@_spi(OwnedTargetVerification) import MLXLMCommon

enum AttentionVerificationChronologyCheck {
    static func run(check: @escaping () throws -> Void) throws -> [String] {
        var cases = 0
        for base in [2, 3, 4, 9] {
            for width in 1...4 {
                for keep in 0...width {
                    try autoreleasepool {
                        let owner = try WindowedStateFixtureOwner(check: check)
                        let plain = try WindowedStateFixtureOwner(check: check)
                        let shaped = try WindowedStateFixtureOwner(check: check)
                        defer { try? owner.close(); try? plain.close(); try? shaped.close() }
                        try AttentionVerificationFixture.fill(owner, to: base)
                        try AttentionVerificationFixture.fill(plain, to: base)
                        try AttentionVerificationFixture.fill(shaped, to: base)
                        let ids = owner.state.rows.map { ObjectIdentifier($0!) }
                        try AttentionVerificationFixture.begin(owner, width: width)
                        let output = try AttentionVerificationFixture.stage(owner, width: width)
                        try AttentionVerificationFixture.require(owner.state.committedTokens == base,
                            "Staged suffix was published before reconciliation")
                        let frontier = try owner.state.reconcileAttentionVerification(keeping: keep, check: check)
                        try AttentionVerificationFixture.require(frontier == base + keep
                            && owner.state.rows.map { ObjectIdentifier($0!) } == ids
                            && owner.state.backend.bytesCapacity == owner.state.geometry.kvCapacityBytes,
                            "Reconciliation replaced rows or retained expanded capacity")
                        let actual = try owner.snapshot()
                        try WindowedStateChronologyCheck.assertSnapshot(actual)
                        let sameShape = try AttentionVerificationFixture.sameShapeReference(shaped, width: width, keep: keep)
                        try AttentionVerificationFixture.require(actual.fingerprint == sameShape.fingerprint,
                            "Owner rollback differs from same-shape SDK transaction")
                        if keep > 0 {
                            let serial = try AttentionVerificationFixture.serial(plain, width: keep)
                            let accepted = output[0..., ..<keep]
                            try AttentionVerificationFixture.require(accepted.asData().data == serial.asData().data,
                                "Synthetic per-query attention differs from serial baseline")
                        }
                        let plainState = try plain.snapshot()
                        try AttentionVerificationFixture.require(actual.fingerprint == plainState.fingerprint,
                            "Accepted synthetic state differs from ordinary prefix")
                        try owner.advance(1); try plain.advance(1)
                        let next = try owner.snapshot(), expected = try plain.snapshot()
                        try AttentionVerificationFixture.require(next.fingerprint == expected.fingerprint,
                            "Rejected suffix contaminated next ordinary decode")
                        try owner.close(); try plain.close(); try shaped.close()
                        cases += 1
                    }
                }
            }
        }
        try AttentionVerificationFixture.require(cases == 56, "Rectangular prefix matrix is incomplete")
        try autoreleasepool {
            let owner = try WindowedStateFixtureOwner(check: check)
            defer { try? owner.close() }
            try owner.advance(7)
            for keep in [1, 2, 3, 4] {
                try AttentionVerificationFixture.begin(owner, width: 4)
                _ = try AttentionVerificationFixture.stage(owner, width: 4)
                _ = try owner.state.reconcileAttentionVerification(keeping: keep, check: check)
                try WindowedStateChronologyCheck.assertSnapshot(owner.snapshot())
            }
            try owner.close()
        }
        try autoreleasepool {
            let owner = try WindowedStateFixtureOwner(check: check)
            defer { try? owner.close() }
            try owner.advance(7)
            let captures = owner.state.rows.map { row -> CBv2OwnedRectangularAttention.Capture in
                let snapshot = row!.snapshot()
                return .init(row: row!, keys: snapshot.keys, values: snapshot.values)
            }
            try CBv2OwnedRectangularAttention.protectCaptures(captures, backend: owner.state.backend, check: check)
            try AttentionVerificationFixture.begin(owner, width: 4)
            _ = try AttentionVerificationFixture.stage(owner, width: 4)
            _ = try owner.state.reconcileAttentionVerification(keeping: 4, check: check)
            for (index, capture) in captures.enumerated() {
                let range = (index == 0 ? 0 : 3)..<7
                let keys = WindowedStateChronologyCheck.expectedBytes(layer: index, range: range, values: false, constant: false)
                let values = WindowedStateChronologyCheck.expectedBytes(layer: index, range: range, values: true, constant: false)
                try AttentionVerificationFixture.require(capture.keys.asData().data == keys
                    && capture.values.asData().data == values, "Pre-write capture changed after committed wrap")
            }
            try owner.close()
        }
        return ["actual-prefill2-decode1-mixed-dtype-probe", "all-56-width-prefix-boundary-cases",
            "same-shape-sdk-rollback-reference", "synthetic-serial-query-output-exact",
            "cpu-encoded-chronological-state-exact", "zero-partial-all-prefix-publication",
            "rejected-suffix-next-decode-isolation", "same-owner-capacity-restoration",
            "repeated-rounds-across-window-wraps", "pre-write-capture-survives-committed-wrap"]
    }
}
#endif
