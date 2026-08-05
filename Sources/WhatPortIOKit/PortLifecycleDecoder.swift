// Decodes IOAccessoryManager lifecycle interest-notification message types.
//
// These codes are private and undocumented. They were observed empirically
// in the WhatCable research corpus (probe 30), from a single M4 Pro capture.
// Treat them as hints, not a stable contract: Apple can change or remove
// them at any time, and other Mac models or macOS versions have not been
// verified to emit the same values.

public enum RawLifecycleSignal: Sendable, Equatable {
    case attach
    case negotiating
    case contractEstablished
    case transportReady
}

public func decodeLifecycleMessage(_ messageType: UInt32) -> RawLifecycleSignal? {
    switch messageType {
    case 0xe3ff80c9:
        return .attach
    case 0xe3ff80ca:
        return .negotiating
    case 0xe3ff80cb:
        return .contractEstablished
    case 0xe3ff8014:
        return .transportReady
    default:
        return nil
    }
}

public struct RawPortLifecycleEvent: Sendable, Equatable {
    public let portNumber: Int
    public let isMagSafe: Bool
    public let signal: RawLifecycleSignal

    public init(portNumber: Int, isMagSafe: Bool, signal: RawLifecycleSignal) {
        self.portNumber = portNumber
        self.isMagSafe = isMagSafe
        self.signal = signal
    }
}
