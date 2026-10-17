/// Steuerzustand eines Monitors, wie ihn die Oberfläche zeigt.
enum DDCState: Equatable, Sendable {
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
    /// Kein Steuerkanal: extern kein DDC-Kanal in der IORegistry, intern lehnt
    /// DisplayServices ab.
    case noChannel

    init(failure error: DDCError) {
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
    var isAdjustable: Bool {
        switch self {
        case .probing, .noChannel: false
        case .ready, .nullReply, .i2cTimeout, .ioError, .noResponse: true
        }
    }

    var isFailure: Bool {
        switch self {
        case .nullReply, .i2cTimeout, .ioError, .noResponse: true
        case .probing, .ready, .noChannel: false
        }
    }

    /// Kurzform für Diagnose und Log.
    var summary: String {
        switch self {
        case .probing: "Abfrage läuft"
        case .ready: "Bereit"
        case .nullReply: "Null-Antwort (6E 80 BE)"
        case .i2cTimeout: "I2C-Timeout, Kanal blockiert"
        case .ioError(let status): "I/O-Fehler \(IOReturnDescription.describe(status))"
        case .noResponse: "Ungültige Antwort"
        case .noChannel: "Kein Steuerkanal"
        }
    }
}
