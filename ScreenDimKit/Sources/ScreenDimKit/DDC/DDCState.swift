import Foundation

/// Steuerzustand eines Monitors, wie ihn die Oberfläche zeigt.
public enum DDCState: Equatable, Sendable {
    /// Erster Read läuft noch.
    case probing
    case ready
    /// Der Monitor antwortet nur mit der DDC-Null-Message (DDC/CI aus, Eco-/Eye-Saver-Modus).
    case nullReply
    /// Der I2C-Kanal blockiert: Aufrufe überschreiten die Deadline oder hängen im Kernel.
    case i2cTimeout
    /// IOKit meldet einen Fehler (IOReturn).
    case ioError(Int32)
    /// Sonstige Antwortfehler: Prüfsumme, unvollständige Antwort, VCP-Code unbekannt.
    case noResponse
    /// Kein Steuerkanal: extern kein DDC-Kanal (oder Variante ohne DDC), intern lässt
    /// sich die Helligkeit nicht steuern.
    case noChannel
    /// Der Nutzer hat DDC/CI in den Einstellungen ausgeschaltet; der Monitor läuft per
    /// Software-Dimmung, ohne I2C-Verkehr.
    case disabled

    public init(failure error: DDCError) {
        switch error {
        case .nullReply:
            self = .nullReply
        case .timeout, .hung, .busy:
            self = .i2cTimeout
        case .writeFailed(let status), .readFailed(let status):
            self = .ioError(status)
        case .malformedReply, .checksumMismatch, .unsupportedCode:
            self = .noResponse
        }
    }

    /// Regelbar ist alles außer „läuft noch“ und „kein Kanal“: Manche Monitore
    /// beantworten keine Reads, nehmen Writes aber an.
    public var isAdjustable: Bool {
        switch self {
        case .probing, .noChannel, .disabled: false
        case .ready, .nullReply, .i2cTimeout, .ioError, .noResponse: true
        }
    }

    public var isFailure: Bool {
        switch self {
        case .nullReply, .i2cTimeout, .ioError, .noResponse: true
        case .probing, .ready, .noChannel, .disabled: false
        }
    }

    /// Kurzform für Diagnose und Log.
    public var summary: String {
        switch self {
        case .probing: String(localized: "Abfrage läuft")
        case .ready: String(localized: "Bereit")
        case .nullReply: String(localized: "Null-Antwort (6E 80 BE)")
        case .i2cTimeout: String(localized: "I2C-Timeout, Kanal blockiert")
        case .ioError(let status): String(localized: "I/O-Fehler \(IOReturnDescription.describe(status))")
        case .noResponse: String(localized: "Ungültige Antwort")
        case .noChannel: String(localized: "Kein Steuerkanal")
        case .disabled: String(localized: "DDC/CI ausgeschaltet")
        }
    }
}
