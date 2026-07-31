import Foundation
import IOKit

// Reads per-port power-OUT from the System Management Controller (SMC).
//
// On desktops (Mac mini / Studio / Pro) there is no battery controller, so the
// AppleSmartBattery power paths the laptop pipeline uses are empty. The per-port
// power-OUT figures still exist; they live in the SMC on channels D1..D4. Each
// channel carries a `DxUI` key whose value equals the port controller's HPM
// `UUID`, which is how a channel is tied to a physical port. The SMC D-index is
// NOT the physical port number (verified on M5: D3 = USB-C@4, D4 = MagSafe@1),
// so the UUID is the only correct join.
//
// This opens an AppleSMC user client (the long-standing public ABI used by
// powermetrics / smcFanControl), unlike every other reader which reads IOKit
// registry properties. All reads are read-only. If the open ever fails, every
// method degrades to "no data" rather than crashing.

public struct RawSMCPortPower: Sendable {
    public let channel: Int       // SMC D-index (1..4), NOT the physical port
    public let present: Bool      // DxPR: something is drawing on this channel
    public let volts: Double      // DxJV
    public let amps: Double       // DxJI
    public let uuid: String       // DxUI, 32-char lowercase hex (join key)

    public var watts: Double { volts * amps }
}

// The negotiated charging contract as the SMC reports it, per channel.
//
// Distinct from RawSMCPortPower, which is power the Mac is sourcing OUT of a
// port. This is the contract for power coming IN, and on M1 Pro / Max / Ultra
// it is the only place that contract exists: those machines never publish a
// USB-C IOPortFeaturePowerSource node, so ChargerReader finds nothing and the
// port shows no power at all while the Mac charges at 100 W.
//
// The integer keys are BIG-endian. The float keys on the same channel (DxJV,
// DxJI) are native little-endian, so the two cannot share a decoder. That is
// not a subtle failure: 20000 mV read the wrong way round is 553,648,128.
public struct RawSMCPortContract: Sendable {
    public let channel: Int       // SMC D-index (1..4), NOT the physical port
    public let uuid: String       // DxUI, 32-char lowercase hex (join key)
    public let powerMW: Int       // DxMP, contract power in milliwatts
    public let voltageMV: Int     // DxMV, contract voltage in millivolts
    public let currentMA: Int     // DxMI, contract current in milliamps
    // DxDE, the channel label. Often empty even on a genuine 20 V charger, so
    // its absence proves nothing. Useful only for spotting a channel that is
    // sourcing power outward ("usb host") rather than receiving it.
    public let label: String
}

// System DC-in (wall / charger) power from the SMC rails. Live (~1 Hz), unlike
// AppleSmartBattery.SystemPowerIn which freezes under load on Apple Silicon.
public struct RawSMCSystemPower: Sendable {
    public let volts: Double      // VD0R, DC-in voltage
    public let amps: Double       // ID0R, DC-in current
    public let watts: Double      // PDTR, or volts * amps when PDTR is absent
}

// @unchecked Sendable: the AppleSMC connection is a single io_connect_t guarded
// by `lock`, so one persisted instance can be shared across the notifier queue
// and the poll task. Every public entry point takes the lock before touching the
// connection, serialising the IOConnectCallStructMethod calls.
public final class SMCPowerReader: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let lock = NSLock()

    public init() {
        // The kernel reads this struct at fixed C offsets and rejects any other
        // size. Catch a layout regression in debug builds.
        assert(
            MemoryLayout<SMCParamStruct>.stride == 80,
            "SMCParamStruct must be 80 bytes, got \(MemoryLayout<SMCParamStruct>.stride)"
        )
    }

    deinit { close() }

    // Opens the AppleSMC user client. Idempotent. Returns false when AppleSMC
    // is missing or the open is refused.
    @discardableResult
    public func open() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return openLocked()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    // Assumes `lock` is held. Used directly by readPortPowerChannels (which
    // already holds the lock) to avoid re-entering the non-recursive NSLock.
    private func openLocked() -> Bool {
        if connection != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return false }
        connection = conn
        return true
    }

    // Reads channels D1..D4. A channel is only returned when it has a usable
    // DxUI, since without it the channel can't be tied to a port. The lock is
    // held for the whole read so concurrent callers serialise on the connection.
    public func readPortPowerChannels() -> [RawSMCPortPower] {
        lock.lock()
        defer { lock.unlock() }
        guard openLocked() else { return [] }
        return Self.buildPortPowerChannels(readKey: { self.readKey($0) })
    }

    // The channel rules, given a way to read a key's bytes. Split out from the
    // kernel round-trips so recorded key dumps from other Macs can be replayed
    // through the real decoders; the method above is then only responsible for
    // opening the SMC and fetching bytes.
    static func buildPortPowerChannels(readKey: (String) -> [UInt8]?) -> [RawSMCPortPower] {
        var channels: [RawSMCPortPower] = []
        for index in 1...4 {
            guard let uuid = readKey("D\(index)UI").flatMap(decodeUUID), !uuid.isEmpty else { continue }
            channels.append(RawSMCPortPower(
                channel: index,
                present: (readKey("D\(index)PR")?.first ?? 0) >= 1,
                volts: Double(readKey("D\(index)JV").flatMap(decodeFloat) ?? 0),
                amps: Double(readKey("D\(index)JI").flatMap(decodeFloat) ?? 0),
                uuid: uuid
            ))
        }
        return channels
    }

    // Reads the negotiated charging contract on channels D1..D4.
    //
    // A channel is only returned when it has a usable DxUI (without it nothing
    // can be tied to a port) and a positive power figure. Returns [] when the
    // SMC can't be opened or the keys are absent, which includes every desktop:
    // DxMP / DxMV / DxMI are missing on all 83 desktops in the WhatCable probe
    // corpus while the power-OUT keys next door are present and working.
    //
    // Callers should only reach for this when the Mac is actually taking power
    // in. Each channel costs up to four kernel round trips, and on a machine
    // that already publishes the power-source node they buy nothing.
    public func readPortContracts() -> [RawSMCPortContract] {
        lock.lock()
        defer { lock.unlock() }
        guard openLocked() else { return [] }
        return Self.buildPortContracts(readKey: { self.readKey($0) })
    }

    // The contract rules, given a way to read a key's bytes. Same seam as
    // buildPortPowerChannels, and the reason the two cannot share a decoder:
    // these keys are big-endian integers while the power ones next door are
    // native little-endian floats.
    static func buildPortContracts(readKey: (String) -> [UInt8]?) -> [RawSMCPortContract] {
        var contracts: [RawSMCPortContract] = []
        for index in 1...4 {
            guard let uuid = readKey("D\(index)UI").flatMap(decodeUUID), !uuid.isEmpty else { continue }
            let powerMW = readKey("D\(index)MP").flatMap(decodeBigEndianInt) ?? 0
            guard powerMW > 0 else { continue }
            contracts.append(RawSMCPortContract(
                channel: index,
                uuid: uuid,
                powerMW: powerMW,
                voltageMV: readKey("D\(index)MV").flatMap(decodeBigEndianInt) ?? 0,
                currentMA: readKey("D\(index)MI").flatMap(decodeBigEndianInt) ?? 0,
                label: readKey("D\(index)DE").map(decodeString) ?? ""
            ))
        }
        return contracts
    }

    // Reads system DC-in power from the SMC rails VD0R (volts), ID0R (amps) and
    // PDTR (watts). Returns nil when neither the voltage nor the current rail is
    // present, so the caller can fall back to the battery telemetry. PDTR is the
    // firmware's own total and is preferred over volts * amps.
    public func readSystemPowerInput() -> RawSMCSystemPower? {
        lock.lock()
        defer { lock.unlock() }
        guard openLocked() else { return nil }

        let volts = readFloat("VD0R")
        let amps = readFloat("ID0R")
        guard volts != nil || amps != nil else { return nil }

        let watts = readFloat("PDTR").map(Double.init) ?? (Double(volts ?? 0) * Double(amps ?? 0))
        return RawSMCSystemPower(
            volts: Double(volts ?? 0),
            amps: Double(amps ?? 0),
            watts: watts
        )
    }

    // MARK: - Key reads

    private func readFloat(_ key: String) -> Float? {
        guard let bytes = readKey(key) else { return nil }
        return Self.decodeFloat(bytes)
    }

    // Decode an SMC `flt` payload (4-byte IEEE float, little-endian on Apple
    // Silicon). Returns nil for short payloads and non-finite values: an
    // uninitialised channel can carry an inf/NaN bit pattern, and letting it
    // through would trap downstream unit conversions. Internal for testing.
    static func decodeFloat(_ bytes: [UInt8]) -> Float? {
        guard bytes.count >= 4 else { return nil }
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let value = Float(bitPattern: bits)
        return value.isFinite ? value : nil
    }

    // Integer keys (DxMP is ui32, DxMV / DxMI are ui16): BIG-endian, unlike the
    // float keys in the same channel, which are native little-endian. The float
    // decoder sits a few lines up and is the obvious thing to reach for, which
    // is why this says so. Internal for testing without SMC hardware.
    // Accumulates into UInt64 and converts once at the end. Accumulating
    // straight into Int does not trap (Swift's << discards the overflow bits)
    // but silently yields a negative number for any 8-byte payload with the top
    // bit set: 0xFF...FF reads as -1 rather than nil. The keys we read are ui16
    // and ui32 so nothing exercises it today, and a wrong answer that looks like
    // a real one is exactly what the rest of this file is careful about.
    static func decodeBigEndianInt(_ bytes: [UInt8]) -> Int? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(exactly: value)
    }

    private func readBigEndianInt(_ key: String) -> Int? {
        guard let bytes = readKey(key) else { return nil }
        return Self.decodeBigEndianInt(bytes)
    }

    // `ch8*` keys (DxDE): a fixed-width NUL-padded label.
    private func readString(_ key: String) -> String? {
        guard let bytes = readKey(key) else { return nil }
        return Self.decodeString(bytes)
    }

    static func decodeString(_ bytes: [UInt8]) -> String {
        let trimmed = Array(bytes.prefix { $0 != 0 })
        guard !trimmed.isEmpty else { return "" }
        return String(decoding: trimmed, as: UTF8.self)
    }

    private func readUInt8(_ key: String) -> UInt8? {
        guard let bytes = readKey(key), let first = bytes.first else { return nil }
        return first
    }

    // `hex_` keys (DxUI): 16 raw bytes as 32 lowercase hex chars, matching the
    // dash-stripped lowercase HPM UUID. A channel with no controller reads
    // all-zero; treat that as absent. Internal for testing.
    func readUUID(_ key: String) -> String? {
        guard let bytes = readKey(key) else { return nil }
        return Self.decodeUUID(bytes)
    }

    static func decodeUUID(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return nil }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return hexString(bytes)
    }

    static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SMC ABI

    // Reads one SMC key's raw bytes: ask for its size/type, then read the value.
    private func readKey(_ key: String) -> [UInt8]? {
        guard let fourCC = Self.fourCC(key) else { return nil }

        var info = SMCParamStruct()
        info.key = fourCC
        info.data8 = Self.cmdGetKeyInfo
        guard let infoOut = callDriver(&info) else { return nil }
        let size = infoOut.keyInfo.dataSize
        guard size > 0 else { return nil }

        var read = SMCParamStruct()
        read.key = fourCC
        read.keyInfo.dataSize = size
        read.keyInfo.dataType = infoOut.keyInfo.dataType
        read.data8 = Self.cmdReadKey
        guard let readOut = callDriver(&read) else { return nil }

        let count = Int(min(size, 32))
        var value = readOut.bytes
        return withUnsafeBytes(of: &value) { Array($0.prefix(count)) }
    }

    private func callDriver(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard connection != 0 else { return nil }
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            connection,
            Self.kernelIndex,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
        return kr == KERN_SUCCESS ? output : nil
    }

    // Packs a 4-character key into its FourCC UInt32 (MSB first).
    static func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 4 else { return nil }
        var value: UInt32 = 0
        for scalar in scalars {
            guard scalar.value <= 0xFF else { return nil }
            value = (value << 8) | UInt32(scalar.value)
        }
        return value
    }

    private static let kernelIndex: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdGetKeyInfo: UInt8 = 9
}

// MARK: - AppleSMC user-client ABI structs
//
// Mirror the C layout used by powermetrics / smcFanControl byte-for-byte. Field
// order and types must not change: the kernel reads this struct at fixed
// offsets. MemoryLayout<SMCParamStruct>.stride must be 80 bytes.

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimit = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    // C keeps keyInfo's 3-byte trailing padding before `result`; Swift would
    // otherwise pack `result` into it and shrink the struct to 76 bytes, which
    // the kernel rejects. This explicit pad restores the C offsets (total 80).
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
