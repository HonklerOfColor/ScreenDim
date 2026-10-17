import Foundation
import os

let ddcLog = Logger(subsystem: "com.andreastrabi.ScreenDim", category: "ddc")

/// Ein einzelner I2C-Aufruf (`IOAVServiceWriteI2C` oder `IOAVServiceReadI2C`).
struct I2CTransferRecord: Equatable, Sendable {
    enum Direction: String, Sendable {
        case write = "Write"
        case read = "Read"
    }

    let direction: Direction
    /// IOReturn; 0 bei Erfolg, `nil`, wenn der Fehler nicht von IOKit stammt.
    let status: Int32?
    let error: DDCError?
    let duration: Duration
    /// Write: das gesendete Paket. Read: die Rohantwort (bei Fehler leer).
    let bytes: [UInt8]
    let date: Date
}

/// Ergebnis einer ganzen Operation (inklusive Retries).
struct DDCOperationRecord: Equatable, Sendable {
    enum Kind: String, Sendable {
        case read = "Read"
        case write = "Write"
    }

    let kind: Kind
    let code: UInt8
    /// Read: gelesener aktueller Wert. Write: geschriebener Wert.
    let value: UInt16?
    let maximum: UInt16?
    let error: DDCError?
    let duration: Duration
    let date: Date
}

/// Momentaufnahme eines DDC-Kanals für das Diagnose-Fenster.
struct DDCDiagnostics: Equatable, Sendable {
    var lastWrite: I2CTransferRecord?
    var lastRead: I2CTransferRecord?
    var lastReadOperation: DDCOperationRecord?
    var lastWriteOperation: DDCOperationRecord?
    var pendingCalls = 0
    /// Gesetzt, solange ein Aufruf über seine Deadline hinaus im Kernel hängt.
    var hungSince: Date?
}

extension Duration {
    var milliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1000) + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
