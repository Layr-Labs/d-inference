import Foundation
import Testing
@testable import MLXLMCommon

@Suite("SequenceStateMachine multi-token stop detection")
struct SequenceStateMachineTests {

    @Test("empty machine never matches; rows finish only on max_tokens")
    func emptyMachineNeverMatches() {
        let machine = SequenceStateMachine()
        var state = machine.makeState()
        for token in [1, 2, 3, 100, 200] {
            let (next, matched, current) = machine.match(state, token)
            #expect(matched == nil)
            #expect(current == nil) // no states defined
            state = next
        }
    }

    @Test("single-token EOS sequence terminates immediately")
    func singleTokenEOS() {
        let eosID = 42
        let machine = SequenceStateMachine(
            states: ["normal": [(sequence: [eosID], next: nil)]],
            initial: "normal"
        )
        var state = machine.makeState()

        // Non-EOS tokens: no match.
        let (s1, m1, c1) = machine.match(state, 7)
        #expect(m1 == nil)
        #expect(c1 == "normal")
        state = s1

        // EOS token: terminal match.
        let (_, m2, c2) = machine.match(state, eosID)
        #expect(m2 == [eosID])
        #expect(c2 == nil) // row terminated
    }

    @Test("multi-token sequence matches only on the full sequence")
    func multiTokenSequence() {
        // "im_end" sequence of 3 tokens: [101, 102, 103]
        let machine = SequenceStateMachine(
            states: ["normal": [(sequence: [101, 102, 103], next: nil)]],
            initial: "normal"
        )
        var state = machine.makeState()

        // Non-matching prefix.
        let (s1, m1, _) = machine.match(state, 101)
        #expect(m1 == nil) // partial -- still in trie
        state = s1
        let (s2, m2, _) = machine.match(state, 999) // mismatch
        #expect(m2 == nil)
        state = s2

        // Now restart and match all three.
        let (s3, m3, _) = machine.match(state, 101)
        #expect(m3 == nil)
        let (s4, m4, _) = machine.match(s3, 102)
        #expect(m4 == nil)
        let (_, m5, c5) = machine.match(s4, 103)
        #expect(m5 == [101, 102, 103])
        #expect(c5 == nil)
    }

    @Test("partial match is reset on mismatch")
    func partialResetOnMismatch() {
        // Sequence [1, 2, 3]
        let machine = SequenceStateMachine(
            states: ["normal": [(sequence: [1, 2, 3], next: nil)]]
        )
        var state = machine.makeState()
        let (s1, _, _) = machine.match(state, 1) // partial
        let (s2, _, _) = machine.match(s1, 99) // mismatch -> reset
        state = s2

        // Now we should need to start over -- token 2 alone shouldn't trigger anything.
        let (_, m, _) = machine.match(state, 2)
        #expect(m == nil)
    }

    @Test("two competing terminal sequences both work")
    func twoCompetingSequences() {
        let machine = SequenceStateMachine(
            states: ["normal": [
                (sequence: [10], next: nil),
                (sequence: [20, 21], next: nil),
            ]]
        )
        var state = machine.makeState()

        // Hit first sequence.
        let (_, m1, _) = machine.match(state, 10)
        #expect(m1 == [10])

        // Hit second sequence.
        state = machine.makeState()
        let (s1, m2, _) = machine.match(state, 20)
        #expect(m2 == nil)
        let (_, m3, _) = machine.match(s1, 21)
        #expect(m3 == [20, 21])
    }
}
