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
    // Whether the PD fields above have ever been set (explicitly via "Reset
    // Health Counters", or automatically on first sight of a port's PD
    // counters, see FlightRecorder.recordSnapshot). Needed because the PD
    // fields themselves default to 0, which is indistinguishable from a
    // deliberate zero baseline: without this marker there is no way to tell
    // "never baselined" from "baselined at zero", so a fresh install could
    // never trigger the auto-baseline (DAR-289). Added after the fields
    // above, for the same backward-compat reason: a payload persisted
    // before this marker existed decodes fine (see init(from:)), reading
    // true if it already carries any PD key (it can only have been written
    // by a pre-marker explicit reset) or false otherwise, either way the
    // correct answer for whether that port's PD counters were baselined.
    public let pdBaselined: Bool

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
        pdDetachCount: Int = 0,
        pdBaselined: Bool = false
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
        self.pdBaselined = pdBaselined
    }

    private enum CodingKeys: String, CodingKey {
        case overcurrentCount, linkErrorCount, enumerationFailureCount, addressFailureCount, ldcmStatus
        case pdHardResetCount, pdShortDetectCount, pdRoleSwapFailCount, pdI2cErrorCount
        case pdAttachCount, pdDetachCount, pdBaselined
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
        // Decode into optionals first, and keep them around, so the marker
        // fallback below can tell "key present" from "key absent" -- the
        // already-decoded Int values (defaulted to 0) can't tell those apart
        // any more.
        let hardResetCount = try container.decodeIfPresent(Int.self, forKey: .pdHardResetCount)
        let shortDetectCount = try container.decodeIfPresent(Int.self, forKey: .pdShortDetectCount)
        let roleSwapFailCount = try container.decodeIfPresent(Int.self, forKey: .pdRoleSwapFailCount)
        let i2cErrorCount = try container.decodeIfPresent(Int.self, forKey: .pdI2cErrorCount)
        let attachCount = try container.decodeIfPresent(Int.self, forKey: .pdAttachCount)
        let detachCount = try container.decodeIfPresent(Int.self, forKey: .pdDetachCount)
        pdHardResetCount = hardResetCount ?? 0
        pdShortDetectCount = shortDetectCount ?? 0
        pdRoleSwapFailCount = roleSwapFailCount ?? 0
        pdI2cErrorCount = i2cErrorCount ?? 0
        pdAttachCount = attachCount ?? 0
        pdDetachCount = detachCount ?? 0
        // A payload carrying the explicit marker decodes to whatever it
        // says. One without the marker but WITH any PD key present can only
        // have been written by a pre-marker build's explicit "Reset Health
        // Counters" (the only path that ever wrote PD keys before the
        // marker existed), so it decodes as baselined too -- otherwise the
        // very next snapshot after upgrading would silently overwrite that
        // user's explicit baseline via the auto-baseline. A payload with no
        // PD keys at all (pre-PD-fields payload, or a port that was never
        // touched) still decodes false, the correct "never baselined" state
        // that lets the auto-baseline fire on next sight.
        let anyPDKeyPresent = hardResetCount != nil || shortDetectCount != nil
            || roleSwapFailCount != nil || i2cErrorCount != nil
            || attachCount != nil || detachCount != nil
        pdBaselined = try container.decodeIfPresent(Bool.self, forKey: .pdBaselined) ?? anyPDKeyPresent
    }
}
