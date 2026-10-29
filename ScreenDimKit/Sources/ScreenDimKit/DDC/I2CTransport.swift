/// Ein I2C-Kanal zu genau einem Monitor.
///
/// Die Aufrufe blockieren (teils mehrere Sekunden) und werden nur von der seriellen
/// Queue des zugehörigen `DDCService` aus benutzt. Die echte Umsetzung braucht private
/// API und liegt deshalb nur in der Direct-Variante der App, nicht in diesem Paket.
public protocol I2CTransport: Sendable {
    func write(_ bytes: [UInt8]) throws(DDCError)
    func read(count: Int) throws(DDCError) -> [UInt8]
}
