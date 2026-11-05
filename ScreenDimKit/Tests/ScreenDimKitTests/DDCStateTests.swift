import Testing
@testable import ScreenDimKit

@Suite("Zustandsabbildung")
struct DDCStateTests {
    @Test("Null-Message wird zu .nullReply")
    func nullReply() {
        #expect(DDCState(failure: .nullReply) == .nullReply)
    }

    @Test("Timeout, Hänger und volle Queue werden zu .i2cTimeout", arguments: [DDCError.timeout, .hung, .busy])
    func timeout(_ error: DDCError) {
        #expect(DDCState(failure: error) == .i2cTimeout)
    }

    @Test("IOKit-Fehler behalten ihren IOReturn")
    func ioError() {
        let status = Int32(bitPattern: 0xE000_02CA)
        #expect(DDCState(failure: .writeFailed(status)) == .ioError(status))
        #expect(DDCState(failure: .readFailed(status)) == .ioError(status))
    }

    @Test("Kaputte Antworten werden zu .noResponse", arguments: [DDCError.checksumMismatch, .malformedReply, .unsupportedCode(0x10)])
    func noResponse(_ error: DDCError) {
        #expect(DDCState(failure: error) == .noResponse)
    }

    @Test("Fehlerzustände bleiben regelbar, Probing und kein Kanal nicht")
    func adjustable() {
        #expect(DDCState.nullReply.isAdjustable)
        #expect(DDCState.i2cTimeout.isAdjustable)
        #expect(DDCState.ioError(-1).isAdjustable)
        #expect(!DDCState.probing.isAdjustable)
        #expect(!DDCState.noChannel.isAdjustable)
        #expect(!DDCState.disabled.isAdjustable)
        #expect(!DDCState.disabled.isFailure)
    }
}

@Suite("IOReturn-Namen")
struct IOReturnDescriptionTests {
    @Test("Bekannte Codes")
    func known() {
        #expect(IOReturnDescription.describe(0) == "0x00000000 kIOReturnSuccess")
        #expect(IOReturnDescription.describe(Int32(bitPattern: 0xE000_02D6)) == "0xE00002D6 kIOReturnTimeout")
        #expect(IOReturnDescription.name(Int32(bitPattern: 0xE000_02CA)) == "kIOReturnIOError")
        #expect(IOReturnDescription.describe(Int32(bitPattern: 0x1000_0003)) == "0x10000003 MACH_SEND_INVALID_DEST")
        #expect(DDCError.writeFailed(Int32(bitPattern: 0x1000_0003)).isStaleService)
        #expect(!DDCError.writeFailed(Int32(bitPattern: 0xE000_02CA)).isStaleService)
    }

    @Test("Unbekannter Code wird zerlegt (echter Wert vom S34CG50)")
    func unknown() {
        #expect(IOReturnDescription.describe(Int32(bitPattern: 0xE011_4000))
            == "0xE0114000 unbekannt (sys 0x38, sub 0x045, code 0x0000)")
    }

    @Test("DDCError zeigt IOReturn als Hex und Name")
    func errorDescription() {
        #expect(DDCError.readFailed(Int32(bitPattern: 0xE000_02D6)).description == "readFailed(0xE00002D6 kIOReturnTimeout)")
    }
}
