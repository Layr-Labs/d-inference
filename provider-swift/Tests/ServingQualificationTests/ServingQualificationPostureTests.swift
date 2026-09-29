import Testing

struct ServingQualificationPostureTests {
    private let nominal = QualificationPostureSnapshot(thermalState: 0, lowPowerMode: false)
    private let fair = QualificationPostureSnapshot(thermalState: 1, lowPowerMode: false)

    @Test func fixedMinimumPreventsEarlyAdmissionEvenWhenAlreadyNominal() {
        var gate = QualificationPostureGate()
        #expect(gate.observe(nominal, elapsedMilliseconds: 0) == nil)
        #expect(gate.observe(nominal, elapsedMilliseconds: 19_999) == nil)
        #expect(gate.observe(nominal, elapsedMilliseconds: 20_000) == true)
    }

    @Test func fairOrLowPowerRestartsTheFullStableWindow() {
        for disturbed in [fair, QualificationPostureSnapshot(thermalState: 0, lowPowerMode: true)] {
            var gate = QualificationPostureGate()
            #expect(gate.observe(nominal, elapsedMilliseconds: 0) == nil)
            #expect(gate.observe(disturbed, elapsedMilliseconds: 19_000) == nil)
            #expect(gate.observe(nominal, elapsedMilliseconds: 20_000) == nil)
            #expect(gate.observe(nominal, elapsedMilliseconds: 24_999) == nil)
            #expect(gate.observe(nominal, elapsedMilliseconds: 25_000) == true)
        }
    }

    @Test func recoveryDeadlineFailsWithoutAdmittingAnotherTrial() {
        var gate = QualificationPostureGate()
        #expect(gate.observe(fair, elapsedMilliseconds: 0) == nil)
        #expect(gate.observe(fair, elapsedMilliseconds: 179_999) == nil)
        #expect(gate.observe(fair, elapsedMilliseconds: 180_000) == false)
        var stalled = QualificationPostureGate()
        #expect(stalled.observe(nominal, elapsedMilliseconds: 0) == nil)
        #expect(stalled.observe(nominal, elapsedMilliseconds: 180_001) == false)
    }

    @Test func midTrialFairObservationCannotHideBehindNominalEndpoints() {
        let receipt = QualificationTrialPostureReceipt(before: nominal, after: nominal,
            worstThermalState: 1, lowPowerObserved: false)
        #expect(!receipt.isNominal)
        let lowPower = QualificationTrialPostureReceipt(before: nominal, after: nominal,
            worstThermalState: 0, lowPowerObserved: true)
        #expect(!lowPower.isNominal)
    }
}
