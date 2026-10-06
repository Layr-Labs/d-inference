import Testing

struct ServingQualificationPostureTests {
    private let nominal = QualificationPostureSnapshot(thermalState: 0, lowPowerMode: false, powerSource: "ac", automaticPower: true, powerPolicyAgeMilliseconds: 0)
    private let fair = QualificationPostureSnapshot(thermalState: 1, lowPowerMode: false, powerSource: "ac", automaticPower: true, powerPolicyAgeMilliseconds: 0)
    private let battery = QualificationPostureSnapshot(thermalState: 0, lowPowerMode: false, powerSource: "battery", automaticPower: true, powerPolicyAgeMilliseconds: 0)
    private let unknown = QualificationPostureSnapshot(thermalState: 0, lowPowerMode: false, powerSource: nil, automaticPower: nil, powerPolicyAgeMilliseconds: nil)

    @Test func fixedMinimumPreventsEarlyAdmissionEvenWhenAlreadyNominal() {
        var gate = QualificationPostureGate()
        for time in stride(from: 0, through: 19_500, by: 500) {
            #expect(gate.observe(nominal, elapsedMilliseconds: Double(time)) == nil)
        }
        #expect(gate.observe(nominal, elapsedMilliseconds: 19_999) == nil)
        #expect(gate.observe(nominal, elapsedMilliseconds: 20_000) == true)
        #expect(gate.observations.first?.elapsedMilliseconds == 0)
        #expect(gate.observations.last?.elapsedMilliseconds == 20_000)
    }

    @Test func fairOrLowPowerRestartsTheFullObservedStableWindow() {
        for disturbed in [fair, QualificationPostureSnapshot(thermalState: 0, lowPowerMode: true, powerSource: "ac", automaticPower: true, powerPolicyAgeMilliseconds: 0)] {
            var gate = QualificationPostureGate()
            for time in stride(from: 0, through: 18_500, by: 500) {
                #expect(gate.observe(nominal, elapsedMilliseconds: Double(time)) == nil)
            }
            #expect(gate.observe(disturbed, elapsedMilliseconds: 19_000) == nil)
            #expect(gate.observe(disturbed, elapsedMilliseconds: 19_500) == nil)
            for time in stride(from: 20_000, through: 24_500, by: 500) {
                #expect(gate.observe(nominal, elapsedMilliseconds: Double(time)) == nil)
            }
            #expect(gate.observe(nominal, elapsedMilliseconds: 24_999) == nil)
            #expect(gate.observe(nominal, elapsedMilliseconds: 25_000) == true)
            #expect(gate.nominalSinceMilliseconds == 20_000)
        }
    }

    @Test func recoveryDeadlineFailsWithoutAdmittingAnotherTrial() {
        var gate = QualificationPostureGate()
        for time in stride(from: 0, through: 179_500, by: 500) {
            #expect(gate.observe(fair, elapsedMilliseconds: Double(time)) == nil)
        }
        #expect(gate.observe(fair, elapsedMilliseconds: 179_999) == nil)
        #expect(gate.observe(fair, elapsedMilliseconds: 180_000) == false)
    }

    @Test func nonACOrUnknownSourceImmediatelyFailsAndCannotRecoverBehindACEndpoints() {
        for source in [battery, unknown] {
            var gate = QualificationPostureGate()
            #expect(gate.observe(nominal, elapsedMilliseconds: 0) == nil)
            #expect(gate.observe(source, elapsedMilliseconds: 500) == false)
            #expect(gate.observe(nominal, elapsedMilliseconds: 1000) == false)
            #expect(gate.observations.count == 3)
            let history = QualificationPostureHistory(initial: nominal)
            history.observe(source, elapsedMilliseconds: 500)
            let receipt = history.finish(after: nominal, elapsedMilliseconds: 1000)
            #expect(receipt.before == nominal && receipt.after == nominal)
            #expect(!receipt.isNominal)
            #expect(receipt.observations[1].snapshot == source)
        }
        var initialUnknown = QualificationPostureGate()
        #expect(initialUnknown.observe(unknown, elapsedMilliseconds: 0) == false)
    }

    @Test func missingOrNonIncreasingSamplesCannotCertifyAnUnobservedInterval() {
        for elapsed in [1000.001, 0, -1, Double.infinity] {
            var gate = QualificationPostureGate()
            #expect(gate.observe(nominal, elapsedMilliseconds: 0) == nil)
            #expect(gate.observe(nominal, elapsedMilliseconds: elapsed) == false)
            let history = QualificationPostureHistory(initial: nominal)
            #expect(!history.finish(after: nominal, elapsedMilliseconds: elapsed).isNominal)
        }
        let complete = QualificationPostureHistory(initial: nominal)
        #expect(complete.finish(after: nominal, elapsedMilliseconds: 1000).isNominal)
    }

    @Test func midTrialThermalOrLowPowerCannotHideBehindNominalEndpoints() {
        for source in [fair, QualificationPostureSnapshot(thermalState: 0, lowPowerMode: true, powerSource: "ac", automaticPower: true, powerPolicyAgeMilliseconds: 0)] {
            let history = QualificationPostureHistory(initial: nominal)
            history.observe(source, elapsedMilliseconds: 500)
            #expect(!history.finish(after: nominal, elapsedMilliseconds: 1000).isNominal)
        }
    }

    @Test func nonautomaticUnknownOrStalePolicyCannotHideBehindACSource() {
        let rejected = [
            QualificationPostureSnapshot(thermalState: 0, lowPowerMode: false, powerSource: "ac",
                automaticPower: false, powerPolicyAgeMilliseconds: 0),
            QualificationPostureSnapshot(thermalState: 0, lowPowerMode: false, powerSource: "ac",
                automaticPower: nil, powerPolicyAgeMilliseconds: nil),
            QualificationPostureSnapshot(thermalState: 0, lowPowerMode: false, powerSource: "ac",
                automaticPower: true, powerPolicyAgeMilliseconds: 3000),
            QualificationPostureSnapshot(thermalState: 0, lowPowerMode: false, powerSource: "ac",
                automaticPower: true, powerPolicyAgeMilliseconds: -1)
        ]
        for sample in rejected {
            var gate = QualificationPostureGate()
            #expect(gate.observe(nominal, elapsedMilliseconds: 0) == nil)
            #expect(gate.observe(sample, elapsedMilliseconds: 500) == false)
            let history = QualificationPostureHistory(initial: nominal)
            history.observe(sample, elapsedMilliseconds: 500)
            #expect(!history.finish(after: nominal, elapsedMilliseconds: 1000).isNominal)
        }
    }

    @Test func observationOverflowIsBoundedAndExplicitlyIneligible() {
        let history = QualificationPostureHistory(initial: nominal)
        for index in 1...QualificationPostureObservation.maximumCount {
            history.observe(nominal, elapsedMilliseconds: Double(index) * 500)
        }
        let receipt = history.finish(after: nominal,
            elapsedMilliseconds: Double(QualificationPostureObservation.maximumCount + 1) * 500)
        #expect(receipt.observations.count == QualificationPostureObservation.maximumCount)
        #expect(receipt.droppedObservations == 2)
        #expect(!receipt.isNominal)
    }
}
