#if SCREENDIM_DIRECT
import Foundation
import IOKit
import ScreenDimKit

// Nur in „ScreenDim Direct“: private API, im App Store nicht zulässig.

/// I2C über `IOAVService` (Apple Silicon, DCP). Die Funktionen sind nicht öffentlich
/// deklariert und werden per `dlsym` aus IOKit geladen.
final class IOAVServiceTransport: I2CTransport, @unchecked Sendable {
    // @unchecked: `service` ist ein unveränderliches CF-Objekt. Zugriffe darauf
    // serialisiert der DDCService über seine Queue.
    private let service: CFTypeRef
    private let api: IOAVServiceAPI

    /// `registryEntry` ist ein `DCPAVServiceProxy` aus der IORegistry.
    init?(registryEntry: io_service_t) {
        guard let api = IOAVServiceAPI.shared,
              let service = api.create(kCFAllocatorDefault, registryEntry)?.takeRetainedValue()
        else { return nil }
        self.api = api
        self.service = service
    }

    /// Sucht den `DCPAVServiceProxy` über seine RegistryEntryID.
    convenience init?(registryEntryID: UInt64) {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        self.init(registryEntry: entry)
    }

    func write(_ bytes: [UInt8]) throws(DDCError) {
        let status = bytes.withUnsafeBytes { buffer in
            api.writeI2C(service, DDCPacket.chipAddress, DDCPacket.hostSubaddress, buffer.baseAddress!, UInt32(buffer.count))
        }
        guard status == kIOReturnSuccess else { throw .writeFailed(status) }
    }

    func read(count: Int) throws(DDCError) -> [UInt8] {
        var reply = [UInt8](repeating: 0, count: count)
        let status = reply.withUnsafeMutableBytes { buffer in
            api.readI2C(service, DDCPacket.chipAddress, DDCPacket.hostSubaddress, buffer.baseAddress!, UInt32(buffer.count))
        }
        guard status == kIOReturnSuccess else { throw .readFailed(status) }
        return reply
    }
}

private struct IOAVServiceAPI: @unchecked Sendable {
    // @unchecked: reine C-Funktionszeiger, unveränderlich nach dem Laden.
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias ReadI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    typealias WriteI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn

    let create: Create
    let readI2C: ReadI2C
    let writeI2C: WriteI2C

    static let shared: IOAVServiceAPI? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOAVServiceCreateWithService"),
              let read = dlsym(handle, "IOAVServiceReadI2C"),
              let write = dlsym(handle, "IOAVServiceWriteI2C")
        else { return nil }
        return IOAVServiceAPI(
            create: unsafeBitCast(create, to: Create.self),
            readI2C: unsafeBitCast(read, to: ReadI2C.self),
            writeI2C: unsafeBitCast(write, to: WriteI2C.self)
        )
    }()
}
#endif
