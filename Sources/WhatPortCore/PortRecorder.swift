import Foundation

// Protocol for the port recording engine.
//
// PortManager calls recordSnapshot() on every poll cycle. The concrete
// FlightRecorder implementation lives in WhatPortCore (FlightRecorder.swift,
// excluded from the OSS mirror) and is wired up by the Pro plugin in
// WhatPortPlugins. When no plugin registers a recorder, PortManager.recorder
// stays nil and the optional-chain call is a no-op.
//
// This protocol lives in WhatPortCore so neither PortManager nor the
// host app need to import the Pro module directly.

public protocol PortRecorder: AnyObject, Sendable {
    func recordSnapshot(ports: [PortState], timestamp: Date)

    // Acknowledged lifetime fault counters for a port, if the recorder tracks them.
    // Lets the host app (which only sees `any PortRecorder`) reflect a user's
    // "Reset Health Counters" action in its own UI without importing the Pro module.
    // Defaults to nil, so recorders that don't support it (and the OSS build, which
    // has no recorder) simply see no acknowledgement.
    func acknowledgedCounters(forPort portID: Int) -> AcknowledgedCounters?
}

public extension PortRecorder {
    func acknowledgedCounters(forPort portID: Int) -> AcknowledgedCounters? { nil }
}

// A snapshot of a port's lifetime fault counters at the moment the user chose to
// "acknowledge" them in settings. The health scorer subtracts these, so
// previously-seen counts no longer affect the score and only NEW faults above the
// acknowledged level count. The Mac's port-controller counters are read-only (we
// can't zero them), so this per-user baseline is the honest equivalent of a reset.
//
// Lives here (shared) rather than with the scorer so the host app and the
// PortRecorder seam can name it without depending on the Pro-only scoring code.
public struct AcknowledgedCounters: Sendable, Equatable, Codable {
    public let overcurrentCount: Int
    public let linkErrorCount: Int
    public let enumerationFailureCount: Int
    public let addressFailureCount: Int
    public let ldcmStatus: String
    // USB-PD port-controller lifetime counters (see PDReliabilityCounters).
    // Added after the four fields above; a payload persisted before these
    // existed decodes fine (see init(from:)) with all four reading 0, which
    // is the same "nothing acknowledged yet" baseline a fresh install starts
    // from, so old data can't be mistaken for a stale/wrong baseline.
    public let pdHardResetCount: Int
    public let pdShortDetectCount: Int
    public let pdRoleSwapFailCount: Int
    public let pdI2cErrorCount: Int
    // Attach/detach counts (see PDReliabilityCounters). Added after the four
    // PD fields above, for the same reason: a payload persisted before these
    // existed decodes fine (see init(from:)) with both reading 0, the same
    // "nothing acknowledged yet" baseline a fresh install starts from.
    public let pdAttachCount: Int
    public let pdDetachCount: Int

    public init(
        overcurrentCount: Int = 0,
        linkErrorCount: Int = 0,
        enumerationFailureCount: Int = 0,
        addressFailureCount: Int = 0,
        ldcmStatus: String = "",
        pdHardResetCount: Int = 0,
        pdShortDetectCount: Int = 0,
        pdRoleSwapFailCount: Int = 0,
        pdI2cErrorCount: Int = 0,
        pdAttachCount: Int = 0,
        pdDetachCount: Int = 0
    ) {
        self.overcurrentCount = overcurrentCount
        self.linkErrorCount = linkErrorCount
        self.enumerationFailureCount = enumerationFailureCount
        self.addressFailureCount = addressFailureCount
        self.ldcmStatus = ldcmStatus
        self.pdHardResetCount = pdHardResetCount
        self.pdShortDetectCount = pdShortDetectCount
        self.pdRoleSwapFailCount = pdRoleSwapFailCount
        self.pdI2cErrorCount = pdI2cErrorCount
        self.pdAttachCount = pdAttachCount
        self.pdDetachCount = pdDetachCount
    }

    private enum CodingKeys: String, CodingKey {
        case overcurrentCount, linkErrorCount, enumerationFailureCount, addressFailureCount, ldcmStatus
        case pdHardResetCount, pdShortDetectCount, pdRoleSwapFailCount, pdI2cErrorCount
        case pdAttachCount, pdDetachCount
    }

    // Custom decode so a payload saved before the PD fields existed still
    // decodes: synthesized Codable would fail the whole record on the first
    // missing key, silently discarding every previously-acknowledged
    // overcurrent/link-error/etc. baseline along with it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overcurrentCount = try container.decodeIfPresent(Int.self, forKey: .overcurrentCount) ?? 0
        linkErrorCount = try container.decodeIfPresent(Int.self, forKey: .linkErrorCount) ?? 0
        enumerationFailureCount = try container.decodeIfPresent(Int.self, forKey: .enumerationFailureCount) ?? 0
        addressFailureCount = try container.decodeIfPresent(Int.self, forKey: .addressFailureCount) ?? 0
        ldcmStatus = try container.decodeIfPresent(String.self, forKey: .ldcmStatus) ?? ""
        pdHardResetCount = try container.decodeIfPresent(Int.self, forKey: .pdHardResetCount) ?? 0
        pdShortDetectCount = try container.decodeIfPresent(Int.self, forKey: .pdShortDetectCount) ?? 0
        pdRoleSwapFailCount = try container.decodeIfPresent(Int.self, forKey: .pdRoleSwapFailCount) ?? 0
        pdI2cErrorCount = try container.decodeIfPresent(Int.self, forKey: .pdI2cErrorCount) ?? 0
        pdAttachCount = try container.decodeIfPresent(Int.self, forKey: .pdAttachCount) ?? 0
        pdDetachCount = try container.decodeIfPresent(Int.self, forKey: .pdDetachCount) ?? 0
    }
}
