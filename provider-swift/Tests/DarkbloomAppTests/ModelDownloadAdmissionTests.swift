import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

@Suite("App model-download admission")
struct ModelDownloadAdmissionTests {
    private let reserve = ModelDownloadStorageContract.appReserveBytes

    @Test("decoded plans are recomputed locally and malformed states fail closed")
    func validatesDecodedFields() {
        let valid = makePlan(remaining: 1_000, available: reserve + 1_000)
        #expect(
            try? ValidatedModelDownloadStoragePlan.validate(
                valid,
                modelID: "org/model"
            ) == .init(
                remainingBytes: 1_000,
                reserveBytes: reserve,
                requiredAvailableBytes: reserve + 1_000,
                availableBytes: reserve + 1_000
            )
        )

        let invalid: [CLIModelDownloadStoragePlan?] = [
            nil,
            makePlan(remaining: 1_000, available: nil, sufficient: false),
            makePlan(
                remaining: 1_000,
                reserve: reserve - 1,
                available: reserve + 1_000
            ),
            makePlan(
                remaining: 1_000,
                available: reserve + 1_000,
                required: reserve + 999
            ),
            makePlan(
                remaining: 1_000,
                available: reserve + 999,
                sufficient: true
            ),
            makePlan(
                remaining: 1_000,
                available: reserve + 1_000,
                sufficient: false
            ),
            CLIModelDownloadStoragePlan(
                remainingBytes: Int64.max,
                reserveBytes: reserve,
                requiredAvailableBytes: Int64.max,
                availableBytes: Int64.max,
                hasSufficientCapacity: true
            ),
            CLIModelDownloadStoragePlan(
                remainingBytes: -1,
                reserveBytes: reserve,
                requiredAvailableBytes: reserve,
                availableBytes: reserve,
                hasSufficientCapacity: true
            ),
        ]

        for plan in invalid {
            #expect(throws: ModelDownloadAdmissionError.self) {
                _ = try ValidatedModelDownloadStoragePlan.validate(
                    plan,
                    modelID: "org/model"
                )
            }
        }
    }

    @Test("simultaneous app admissions cannot spend the same free capacity")
    func concurrentAdmissionsDoNotOvercommit() async {
        let gate = AppModelDownloadAdmissionController()
        let plan = makePlan(
            remaining: 60,
            available: reserve + 100
        )

        let outcomes = await withTaskGroup(
            of: Result<AppModelDownloadAdmissionController.Admission, Error>.self
        ) { group in
            for modelID in ["org/one", "org/two"] {
                group.addTask {
                    do {
                        return .success(try await gate.admit(
                            modelID: modelID,
                            plan: plan
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var values:
                [Result<AppModelDownloadAdmissionController.Admission, Error>] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        let admitted = outcomes.compactMap { try? $0.get() }
        #expect(admitted.count == 1)
        #expect(outcomes.count == 2)
        #expect(await gate.reservationSnapshot().count == 1)
        if let admission = admitted.first {
            await gate.release(admission)
        }
        let released = await gate.reservationSnapshot()
        #expect(released.count == 0)
        #expect(released.bytes == 0)
    }

    private func makePlan(
        remaining: Int64,
        reserve reserveBytes: Int64? = nil,
        available: Int64?,
        required requiredBytes: Int64? = nil,
        sufficient: Bool? = nil
    ) -> CLIModelDownloadStoragePlan {
        let reserveBytes = reserveBytes ?? reserve
        let computedRequired = remaining.addingReportingOverflow(reserveBytes)
        let required = requiredBytes
            ?? (computedRequired.overflow ? Int64.max : computedRequired.partialValue)
        return CLIModelDownloadStoragePlan(
            remainingBytes: remaining,
            reserveBytes: reserveBytes,
            requiredAvailableBytes: required,
            availableBytes: available,
            hasSufficientCapacity: sufficient
                ?? (available.map { !computedRequired.overflow && $0 >= required } ?? false)
        )
    }
}
