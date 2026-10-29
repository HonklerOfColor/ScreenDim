import Foundation
import os

let ddcLog = Logger(subsystem: "com.andreastrabi.ScreenDim", category: "ddc")

/// Ein einzelner I2C-Aufruf (Write oder Read über den `I2CTransport`).
public struct I2CTransferRecord: Equatable, Sendable {
    public enum Direction: String, Sendable {
        case write = "Write"
        case read = "Read"
    }

    public let direction: Direction
    /// IOReturn; 0 bei Erfolg, `nil`, wenn der Fehler nicht von IOKit stammt.
    public let status: Int32?
    public let error: DDCError?
    public let duration: Duration
    /// Write: das gesendete Paket. Read: die Rohantwort (bei Fehler leer).
    public let bytes: [UInt8]
    public let date: Date
}

/// Ergebnis einer ganzen Operation (inklusive Retries).
public struct DDCOperationRecord: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case read = "Read"
        case write = "Write"
    }

    public let kind: Kind
    public let code: UInt8
    /// Read: gelesener aktueller Wert. Write: geschriebener Wert.
    public let value: UInt16?
    public let maximum: UInt16?
    public let error: DDCError?
    public let duration: Duration
    public let date: Date
}

/// Momentaufnahme eines DDC-Kanals für das Diagnose-Fenster.
public struct DDCDiagnostics: Equatable, Sendable {
    public var lastWrite: I2CTransferRecord?
    public var lastRead: I2CTransferRecord?
    public var lastReadOperation: DDCOperationRecord?
    public var lastWriteOperation: DDCOperationRecord?
    public var pendingCalls = 0
    /// Gesetzt, solange ein Aufruf über seine Deadline hinaus im Kernel hängt.
    public var hungSince: Date?
}

extension Duration {
    public var milliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1000) + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
