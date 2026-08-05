import Testing
@testable import WhatPortIOKit

// The SMC's integer keys (DxMP / DxMV / DxMI) are big-endian while the float
// keys on the same channel are native little-endian, so the two decoders are
// separate on purpose. These pin the boundaries of the integer one.

@Test func bigEndianDecodeReadsRealContractValues() {
    // The reporter's contract, and this machine's own: 20 V, 100 W, 4.7 A.
    #expect(SMCPowerReader.decodeBigEndianInt([0x4E, 0x20]) == 20_000)
    #expect(SMCPowerReader.decodeBigEndianInt([0x00, 0x01, 0x86, 0xA0]) == 100_000)
    #expect(SMCPowerReader.decodeBigEndianInt([0x12, 0x52]) == 4_690)
}

// Little-endian would read 20000 mV as 8270, which still LOOKS like a voltage.
// That is why the two decoders can never be shared.
@Test func bigEndianDecodeIsNotByteSwapped() {
    #expect(SMCPowerReader.decodeBigEndianInt([0x4E, 0x20]) != 0x204E)
}

@Test func bigEndianDecodeRejectsPayloadsItCannotRepresent() {
    #expect(SMCPowerReader.decodeBigEndianInt([]) == nil)
    #expect(SMCPowerReader.decodeBigEndianInt([UInt8](repeating: 0xFF, count: 9)) == nil)

    // Eight bytes above Int.max: nil, not a negative number. Accumulating
    // straight into Int does not trap, it silently returns -1 here, and a wrong
    // answer shaped like a real one is the failure mode worth closing.
    #expect(SMCPowerReader.decodeBigEndianInt([UInt8](repeating: 0xFF, count: 8)) == nil)
    #expect(SMCPowerReader.decodeBigEndianInt([0x80, 0, 0, 0, 0, 0, 0, 0]) == nil)

    // Int.max itself still decodes.
    #expect(SMCPowerReader.decodeBigEndianInt([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == Int.max)
}

// System DC-in power (VD0R/ID0R/PDTR). PDTR is the firmware's own total and
// is preferred outright over volts * amps when present, even when the two
// disagree -- this pins that PDTR wins, not just that it's read.
@Test func systemPowerPrefersPDTROverVoltsTimesAmps() {
    func encodeFloat(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }

    let keys: [String: [UInt8]] = [
        "VD0R": encodeFloat(20.0),
        "ID0R": encodeFloat(5.0),
        "PDTR": encodeFloat(97.5)   // Deliberately not 20 * 5 = 100.
    ]

    let result = SMCPowerReader.buildSystemPowerInput(readKey: { keys[$0] })
    #expect(result?.volts == 20.0)
    #expect(result?.amps == 5.0)
    #expect(result?.watts == 97.5)
}

// Without PDTR, watts falls back to volts * amps.
@Test func systemPowerFallsBackToVoltsTimesAmpsWithoutPDTR() {
    func encodeFloat(_ value: Float) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }

    let keys: [String: [UInt8]] = [
        "VD0R": encodeFloat(9.0),
        "ID0R": encodeFloat(2.0)
    ]

    let result = SMCPowerReader.buildSystemPowerInput(readKey: { keys[$0] })
    #expect(result?.watts == 18.0)
}

// Neither rail present -> nil, so the caller falls back to battery telemetry.
@Test func systemPowerIsNilWithoutEitherRail() {
    #expect(SMCPowerReader.buildSystemPowerInput(readKey: { _ in nil }) == nil)
}
