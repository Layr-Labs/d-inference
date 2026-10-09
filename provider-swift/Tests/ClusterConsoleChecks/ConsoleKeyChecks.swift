import Foundation
@testable import InstalledContract

extension ClusterConsoleCheck {
    private static func keys(_ chunks: [[UInt8]], flush: Bool = false) -> [ClusterConsoleKey] {
        var decoder = ClusterConsoleKeyDecoder(), result = [ClusterConsoleKey]()
        for chunk in chunks { result += decoder.feed(chunk) }
        if flush { result += decoder.flush() }
        return result
    }

    static func keyDecoder() throws {
        let escape: UInt8 = 0x1B
        func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

        expectEqual(keys([bytes("qr?")]), [.character("q"), .character("r"), .character("?")], "printable characters")
        expectEqual(keys([[0x03, 0x04, 0x09, 0x0D, 0x0A, 0x7F, 0x08]]),
            [.interrupt, .endOfInput, .tab, .enter, .enter, .backspace, .backspace], "control keys")
        expectEqual(keys([[escape] + bytes("[A"), [escape] + bytes("[B"), [escape] + bytes("[C"), [escape] + bytes("[D")]),
            [.up, .down, .right, .left], "arrow keys")
        expectEqual(keys([[escape] + bytes("OA"), [escape] + bytes("OB"), [escape] + bytes("OH"), [escape] + bytes("OF")]),
            [.up, .down, .home, .end], "application-mode arrow keys")
        expectEqual(keys([[escape] + bytes("[5~"), [escape] + bytes("[6~"), [escape] + bytes("[H"), [escape] + bytes("[F"),
                          [escape] + bytes("[1~"), [escape] + bytes("[4~"), [escape] + bytes("[7~"), [escape] + bytes("[8~")]),
            [.pageUp, .pageDown, .home, .end, .home, .end, .home, .end], "paging keys")

        // An escape sequence split across reads, one byte at a time.
        expectEqual(keys([[escape], bytes("["), bytes("A")]), [.up], "an arrow split over three reads")
        expectEqual(keys([[escape, UInt8(ascii: "[")], bytes("5"), bytes("~"), bytes("q")]), [.pageUp, .character("q")],
            "page up split over three reads, then a character")
        expectEqual(keys([[escape, UInt8(ascii: "O")], bytes("B")]), [.down], "an application-mode arrow split over two reads")

        // A lone escape byte is the Escape key only once nothing follows it.
        var decoder = ClusterConsoleKeyDecoder()
        expectEqual(decoder.feed([escape]), [], "a lone escape byte must wait for what follows")
        expect(decoder.hasPending, "the escape byte is pending")
        expectEqual(decoder.flush(), [.escape], "nothing followed: it was the Escape key")
        expect(!decoder.hasPending, "flush leaves nothing pending")
        expectEqual(decoder.flush(), [], "a second flush has nothing to say")
        expectEqual(keys([[escape, escape]], flush: true), [.escape, .escape], "two escape bytes are two Escape keys")
        expectEqual(keys([[escape] + bytes("[")], flush: true), [.unknown], "an unfinished sequence is dropped as one unknown key")

        // Sequences the screen has no use for are consumed whole.
        expectEqual(keys([[escape] + bytes("[1;5C")]), [.unknown], "a modified arrow is one unknown key")
        // A paste is dropped whole: nothing in it is a key, however it is cut into reads.
        let paste = [escape] + bytes("[200~today say quit\u{03}") + [escape] + bytes("[201~")
        expectEqual(keys([paste + bytes("r")]), [.unknown, .character("r")], "a paste is one unknown key, and typing continues after it")
        expectEqual(keys(paste.map { [$0] } + [bytes("r")]), [.unknown, .character("r")], "a paste arriving one byte at a time")
        expectEqual(keys([[escape] + bytes("[200~ay"), bytes("sy"), [escape], bytes("[20"), bytes("1~"), bytes("q")]),
            [.unknown, .character("q")], "the end of a paste split across reads")
        var pasting = ClusterConsoleKeyDecoder()
        expectEqual(pasting.feed([escape] + bytes("[200~") + [UInt8](repeating: UInt8(ascii: "y"), count: 100_000)), [], "a long paste yields nothing while it lasts")
        expect(!pasting.hasPending, "an open paste is not an unfinished key sequence")
        expectEqual(pasting.flush(), [], "and a pause inside it yields nothing")
        expectEqual(pasting.feed(bytes("yyyy") + [escape] + bytes("[201~")) + pasting.feed(bytes("?")), [.unknown, .character("?")],
            "it ends only with its marker")
        expectEqual(keys([[escape] + bytes("[<0;10;20M")]), [.unknown], "a mouse report is one unknown key")
        expectEqual(keys([[escape] + bytes("x")]), [.unknown], "an Alt chord is one unknown key")
        expectEqual(keys([[0x00, 0x01, 0x1A, 0x1F]]), [.unknown, .unknown, .unknown, .unknown], "other control bytes are unknown")
        expectEqual(keys([Array("é".utf8), Array("日".utf8), Array("😀".utf8)]), [.unknown, .unknown, .unknown],
            "one non-ASCII character is one unknown key")
        expectEqual(keys([[0xE6], [0x97], [0xA5], bytes("q")]), [.unknown, .character("q")], "a UTF-8 character split over reads")
        expectEqual(keys([[0x80, 0xBF, 0xFF]]), [.unknown, .unknown, .unknown], "stray continuation bytes")
        // A control byte inside a control sequence ends it and is read by itself.
        expectEqual(keys([[escape, UInt8(ascii: "["), 0x03]]), [.unknown, .interrupt], "Ctrl-C after an unfinished sequence still arrives")

        // An endless sequence cannot hold input hostage.
        let endless = [escape, UInt8(ascii: "[")] + [UInt8](repeating: UInt8(ascii: "1"), count: 200)
        var flooded = ClusterConsoleKeyDecoder()
        expectEqual(flooded.feed(endless), [.unknown], "an overlong sequence is dropped")
        expect(!flooded.hasPending, "nothing is kept from an overlong sequence")
        expectEqual(flooded.feed(bytes("q")), [.character("q")], "the decoder reads on after dropping one")

        // Every single byte, and a long arbitrary stream cut at arbitrary points.
        for byte in UInt8.min...UInt8.max {
            var single = ClusterConsoleKeyDecoder()
            let produced = single.feed([byte]) + single.flush()
            expect(produced.count == 1, "byte \(byte) produced \(produced.count) keys")
        }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15, stream = ClusterConsoleKeyDecoder(), produced = 0
        func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
        for _ in 0..<4000 {
            let chunk = (0..<Int(next() % 7)).map { _ -> UInt8 in
                // Escape and bracket bytes are frequent, so sequences keep starting.
                switch next() % 6 { case 0: return escape; case 1: return UInt8(ascii: "["); default: return UInt8(truncatingIfNeeded: next()) }
            }
            produced += stream.feed(chunk).count
            if next() % 11 == 0 { produced += stream.flush().count }
        }
        expect(produced > 1000, "the arbitrary stream produced keys: \(produced)")
    }
}
