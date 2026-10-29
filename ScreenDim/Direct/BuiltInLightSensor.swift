#if SCREENDIM_DIRECT
import Foundation
import IOKit.hidsystem
import ScreenDimKit

// Nur in „ScreenDim Direct“: private API, im App Store nicht zulässig.

/// Eingebauter Umgebungslichtsensor (ALS) des Macs als Lichtquelle für den `SensorController`.
/// Liest den HID-Dienst des Sensors über das Event-System von IOKit, dessen Funktionen
/// für Ereignisse nicht öffentlich sind (per `dlsym`, wie DisplayServices). Meldet nur
/// `.connection(.connected)` und `.lux`, keine Anwesenheit.
///
/// Ereignisgesteuert, aber im Takt: Der Sensor schickt einem Client erst etwas, wenn
/// dieser ein `ReportInterval` setzt, und dann in diesem Abstand, auch bei gleichem Licht.
/// 1 s reicht für Raumlicht; Ausreißer fängt die Hysterese im `SensorController` ab. Das
/// Intervall gilt nur für diesen Client; den Takt, den macOS für die Auto-Helligkeit
/// nutzt, ändert es nicht.
///
/// Mac mini und Mac Studio haben keinen Sensor; dann liefert `init` `nil`. Der iMac hat
/// einen; dort gilt dasselbe wie beim MacBook mit offenem Deckel.
final class BuiltInLightSensor: SensorSource {
    static let reportInterval: Duration = .seconds(1)

    private let api: HIDEventSystemAPI

    init?() {
        guard let api = HIDEventSystemAPI.shared, let client = api.makeClient(),
              !api.lightSensors(of: client).isEmpty
        else { return nil }
        self.api = api
    }

    func events() -> AsyncStream<SensorEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            guard let session = LightSensorSession(api: api, continuation: continuation) else {
                continuation.finish()
                return
            }
            continuation.yield(.connection(.connected))
            session.start()
            continuation.onTermination = { _ in session.stop() }
        }
    }
}

/// Ein Client des Event-Systems je Strom. Nach `start()` laufen Callback und Aufräumen
/// nur auf `queue`.
private final class LightSensorSession: @unchecked Sendable {
    // @unchecked: Client und Dienste sind CF-Objekte ohne Sendable; sie werden nach
    // `init` nur noch auf `queue` benutzt.
    private let api: HIDEventSystemAPI
    private let client: IOHIDEventSystemClient
    private let sensors: [IOHIDServiceClient]
    private let continuation: AsyncStream<SensorEvent>.Continuation
    private let queue = DispatchQueue(label: "com.andreastrabi.ScreenDim.light-sensor")

    init?(api: HIDEventSystemAPI, continuation: AsyncStream<SensorEvent>.Continuation) {
        guard let client = api.makeClient() else { return nil }
        let sensors = api.lightSensors(of: client)
        guard !sensors.isEmpty else { return nil }
        self.api = api
        self.client = client
        self.sensors = sensors
        self.continuation = continuation
    }

    func start() {
        // Der Callback hält die Sitzung, bis `stop()` sie freigibt.
        let target = Unmanaged.passRetained(self).toOpaque()
        api.registerEventCallback(client, lightSensorCallback, target, nil)
        api.scheduleWithDispatchQueue(client, queue)
        queue.async { [self] in
            let interval = Self.microseconds(BuiltInLightSensor.reportInterval) as CFNumber
            for sensor in sensors {
                _ = IOHIDServiceClientSetProperty(sensor, kIOHIDReportIntervalKey as CFString, interval)
            }
            // Erster Wert sofort, nicht erst nach dem ersten Intervall.
            if let lux = sensors.lazy.compactMap(api.currentLux(of:)).first {
                continuation.yield(.lux(lux))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            api.unscheduleFromDispatchQueue(client, queue)
            let target = Unmanaged.passUnretained(self).toOpaque()
            api.unregisterEventCallback(client, lightSensorCallback, target, nil)
            // Ereignisse, die schon in der Queue stehen, laufen vor diesem Block.
            queue.async { Unmanaged.passUnretained(self).release() }
        }
    }

    fileprivate func receive(_ event: UnsafeMutableRawPointer) {
        guard let lux = api.lux(of: event) else { return }
        continuation.yield(.lux(lux))
    }

    private static func microseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1_000_000 + Int(duration.components.attoseconds / 1_000_000_000_000)
    }
}

/// Parameter: Ziel, Refcon, Dienst, Ereignis.
private let lightSensorCallback: HIDEventSystemAPI.EventCallback = { target, _, _, event in
    guard let target, let event else { return }
    Unmanaged<LightSensorSession>.fromOpaque(target).takeUnretainedValue().receive(event)
}

/// Die nicht öffentlichen Funktionen des HID-Event-Systems. Öffentlich (IOKit/hidsystem)
/// sind nur `IOHIDEventSystemClientCopyServices` und `IOHIDServiceClientSetProperty`.
private struct HIDEventSystemAPI: @unchecked Sendable {
    // @unchecked: reine C-Funktionszeiger, unveränderlich nach dem Laden.
    typealias EventCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> Void
    typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<IOHIDEventSystemClient>?
    typealias SetMatching = @convention(c) (IOHIDEventSystemClient, CFDictionary) -> Void
    /// Dienst, Ereignistyp, Vorlage (NULL), Optionen.
    typealias CopyEvent = @convention(c) (IOHIDServiceClient, Int64, UnsafeMutableRawPointer?, UInt32) -> UnsafeMutableRawPointer?
    typealias GetType = @convention(c) (UnsafeMutableRawPointer) -> UInt32
    typealias GetFloatValue = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double
    typealias Callback = @convention(c) (IOHIDEventSystemClient, EventCallback, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias Schedule = @convention(c) (IOHIDEventSystemClient, DispatchQueue) -> Void

    /// Apple-Vendor-Page, Usage „Ambient Light Sensor“ (Apple Silicon: Dienst „als“ am SPU).
    static let usagePage = 0xFF00
    static let usage = 4
    /// `kIOHIDEventTypeAmbientLightSensor`; das Feld 0 dieses Typs ist der Wert in Lux.
    static let eventType: UInt32 = 12
    static let luxField = Int32(eventType << 16)

    /// Der vollwertige Client. `IOHIDEventSystemClientCreateSimpleClient` findet den Dienst
    /// zwar, bekommt aber weder Werte noch Ereignisse.
    let create: Create
    let setMatching: SetMatching
    let copyEvent: CopyEvent
    let getType: GetType
    let getFloatValue: GetFloatValue
    let registerEventCallback: Callback
    let unregisterEventCallback: Callback
    let scheduleWithDispatchQueue: Schedule
    let unscheduleFromDispatchQueue: Schedule

    static let shared: HIDEventSystemAPI? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let getType = dlsym(handle, "IOHIDEventGetType"),
              let getFloatValue = dlsym(handle, "IOHIDEventGetFloatValue"),
              let register = dlsym(handle, "IOHIDEventSystemClientRegisterEventCallback"),
              let unregister = dlsym(handle, "IOHIDEventSystemClientUnregisterEventCallback"),
              let schedule = dlsym(handle, "IOHIDEventSystemClientScheduleWithDispatchQueue"),
              let unschedule = dlsym(handle, "IOHIDEventSystemClientUnscheduleFromDispatchQueue")
        else { return nil }
        return HIDEventSystemAPI(
            create: unsafeBitCast(create, to: Create.self),
            setMatching: unsafeBitCast(setMatching, to: SetMatching.self),
            copyEvent: unsafeBitCast(copyEvent, to: CopyEvent.self),
            getType: unsafeBitCast(getType, to: GetType.self),
            getFloatValue: unsafeBitCast(getFloatValue, to: GetFloatValue.self),
            registerEventCallback: unsafeBitCast(register, to: Callback.self),
            unregisterEventCallback: unsafeBitCast(unregister, to: Callback.self),
            scheduleWithDispatchQueue: unsafeBitCast(schedule, to: Schedule.self),
            unscheduleFromDispatchQueue: unsafeBitCast(unschedule, to: Schedule.self)
        )
    }()

    /// Client, der nur die Dienste des Lichtsensors sieht.
    func makeClient() -> IOHIDEventSystemClient? {
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        let matching = [kIOHIDPrimaryUsagePageKey: Self.usagePage, kIOHIDPrimaryUsageKey: Self.usage] as CFDictionary
        setMatching(client, matching)
        return client
    }

    /// Nur eingebaute Sensoren: Ein Bildschirm mit eigenem Lichtsensor am Mac mini darf
    /// nicht als „eingebaut“ gelten.
    func lightSensors(of client: IOHIDEventSystemClient) -> [IOHIDServiceClient] {
        (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []).filter {
            IOHIDServiceClientConformsTo($0, UInt32(Self.usagePage), UInt32(Self.usage)) != 0
                && IOHIDServiceClientCopyProperty($0, kIOHIDBuiltInKey as CFString) as? Bool == true
        }
    }

    func currentLux(of sensor: IOHIDServiceClient) -> Double? {
        guard let event = copyEvent(sensor, Int64(Self.eventType), nil, 0) else { return nil }
        defer { Unmanaged<CFTypeRef>.fromOpaque(event).release() }
        return lux(of: event)
    }

    func lux(of event: UnsafeMutableRawPointer) -> Double? {
        guard getType(event) == Self.eventType else { return nil }
        let value = getFloatValue(event, Self.luxField)
        return value.isFinite && value >= 0 ? value : nil
    }
}
#endif
