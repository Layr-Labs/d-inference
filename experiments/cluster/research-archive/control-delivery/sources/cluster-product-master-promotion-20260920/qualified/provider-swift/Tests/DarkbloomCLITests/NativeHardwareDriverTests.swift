#if NATIVE_PAIR_HARDWARE_EXPERIMENT
import Foundation
import Testing
import ProviderCore
@testable import darkbloom

struct NativeHardwareDriverTests {
    @Test func acceptsOnlyTwoTokensAndLengthTerminal() throws {
        let events=NativeHardwareEvents()
        #expect(events.accept(.token(1654)));#expect(events.accept(.token(421)))
        #expect(events.accept(.finished(.length)))
        #expect(try events.result()==[1654,421])
    }
    @Test func failedOrMissingTerminalCannotQualify() {
        for finish in [false,true] {
            let events=NativeHardwareEvents()
            _=events.accept(.token(1654));_=events.accept(.token(421))
            if finish {_=events.accept(.finished(.cancelled))}
            #expect(throws:(any Error).self){try events.result()}
        }
    }
    @Test func extraOrLateTokensInvalidate() {
        for late in [false,true] {
            let events=NativeHardwareEvents()
            _=events.accept(.token(1654));_=events.accept(.token(421))
            if late {_=events.accept(.finished(.length))}
            #expect(!events.accept(.token(99)))
            #expect(throws:(any Error).self){try events.result()}
        }
    }
    @Test func exactReadRefusesSymlinkAndOverBound() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("input"),link=root.appendingPathComponent("link")
        try Data([1,2,3]).write(to:file)
        try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:file.path)
        #expect(NativeHardwareInput.read(file.path,maximum:3)==Data([1,2,3]))
        #expect(NativeHardwareInput.read(file.path,maximum:2)==nil)
        #expect(NativeHardwareInput.read(link.path,maximum:3)==nil)
    }
}
#endif
