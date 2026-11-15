import Foundation

/// The display matrices an inline ISO BMFF (MP4 or QuickTime) video declares:
/// the movie header's and each video track header's, read from `moov` by a
/// bounded box walk. AVFoundation renders a track's frames through its matrix
/// (`preferredTransform`), so a matrix that scales renders them larger than
/// any size the container's sample descriptions state.
enum ISOBMFFDisplayMatrices {
    /// True only when the file has one `moov`, at least one video track, and
    /// every movie and video track matrix turns or flips the picture by
    /// quarter turns at unit scale, without perspective. False for anything
    /// else, including boxes that can't be read.
    static func onlyQuarterTurns(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var movies = 0
            var videoTracks = 0
            let walked = walk(raw, 0..<raw.count) { type, body in
                guard type == "moov" else { return true }
                movies += 1
                return movies == 1 && walk(raw, body) { type, body in
                    switch type {
                    case "mvhd": return quarterTurn(raw, body, timesBytes: (16, 28), skip: 16)
                    case "trak":
                        guard let track = track(raw, body) else { return false }
                        if track.video { videoTracks += 1 }
                        return !track.video || track.quarterTurn
                    default: return true
                    }
                }
            }
            return walked && movies == 1 && videoTracks > 0
        }
    }

    /// Whether a track is video (`hdlr` `vide`) and its `tkhd` matrix a quarter turn.
    private static func track(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> (video: Bool, quarterTurn: Bool)? {
        var turn: Bool?
        var video = false
        let walked = walk(raw, range) { type, body in
            switch type {
            case "tkhd":
                guard turn == nil else { return false }
                turn = quarterTurn(raw, body, timesBytes: (20, 32), skip: 16)
                return true
            case "mdia":
                return walk(raw, body) { type, body in
                    // Full box header, then pre_defined, then handler_type.
                    guard type == "hdlr" else { return true }
                    guard body.count >= 12 else { return false }
                    video = video || fourCC(raw, body.lowerBound + 8) == "vide"
                    return true
                }
            default: return true
            }
        }
        guard walked, let turn else { return nil }
        return (video, turn)
    }

    /// The full box's matrix, after its version's header fields and `skip`
    /// more bytes: `a b u / c d v / x y w`, with a…d and x, y in 16.16 and
    /// u, v, w in 2.30 fixed point.
    private static func quarterTurn(
        _ raw: UnsafeRawBufferPointer, _ body: Range<Int>, timesBytes: (Int, Int), skip: Int
    ) -> Bool {
        guard body.count >= 4 else { return false }
        let version = raw[body.lowerBound]
        guard version <= 1 else { return false }
        let start = body.lowerBound + 4 + (version == 0 ? timesBytes.0 : timesBytes.1) + skip
        guard start + 36 <= body.upperBound else { return false }
        let m = (0..<9).map { Int32(bitPattern: uint32(raw, start + 4 * $0)) }
        let unit: Set<Int32> = [0, 0x0001_0000, -0x0001_0000]
        guard [m[0], m[1], m[3], m[4]].allSatisfy(unit.contains), m[2] == 0, m[5] == 0, m[8] == 0x4000_0000
        else { return false }
        return (m[0] != 0 && m[4] != 0 && m[1] == 0 && m[3] == 0)
            || (m[0] == 0 && m[4] == 0 && m[1] != 0 && m[3] != 0)
    }

    /// Visits each box in `range` with its type and body; false when a box
    /// overruns its parent, there are too many, or `visit` refuses.
    private static func walk(
        _ raw: UnsafeRawBufferPointer, _ range: Range<Int>, _ visit: (String, Range<Int>) -> Bool
    ) -> Bool {
        var offset = range.lowerBound
        var boxes = 0
        while offset < range.upperBound {
            let remaining = range.upperBound - offset
            boxes += 1
            guard remaining >= 8, boxes <= 4096 else { return false }
            let declared = UInt64(uint32(raw, offset))
            var header = 8
            var size = declared
            if declared == 1 {
                guard remaining >= 16 else { return false }
                size = UInt64(uint32(raw, offset + 8)) << 32 | UInt64(uint32(raw, offset + 12))
                header = 16
            } else if declared == 0 {
                size = UInt64(remaining)
            }
            guard size >= UInt64(header), size <= UInt64(remaining) else { return false }
            guard visit(fourCC(raw, offset + 4), (offset + header)..<(offset + Int(size))) else { return false }
            offset += Int(size)
        }
        return true
    }

    private static func uint32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(raw[offset + $1]) }
    }

    private static func fourCC(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> String {
        String(decoding: raw[offset..<(offset + 4)], as: UTF8.self)
    }
}
