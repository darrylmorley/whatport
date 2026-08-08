import Foundation
import Testing
@testable import WhatPortCore

// AcknowledgedCounters ships in the OSS build (it lives in PortRecorder.swift,
// which is not mirror-excluded), unlike the Health tab scoring logic that
// consumes it. Kept in its own file, separate from HealthScorerTests.swift
// (which is mirror-excluded), so these Codable/backward-compat tests still
// run against the public mirror.

@Suite("AcknowledgedCounters — Codable backward compatibility")
struct AcknowledgedCountersCodableTests {

    @Test("A payload saved before the PD fields existed decodes with zeros")
    func decodingOldPayloadDefaultsPDFieldsToZero() throws {
        let oldPayloadJSON = """
        {
            "overcurrentCount": 3,
            "linkErrorCount": 1,
            "enumerationFailureCount": 0,
            "addressFailureCount": 0,
            "ldcmStatus": "No Error"
        }
        """
        let decoded = try JSONDecoder().decode(AcknowledgedCounters.self, from: Data(oldPayloadJSON.utf8))

        #expect(decoded.overcurrentCount == 3)
        #expect(decoded.linkErrorCount == 1)
        #expect(decoded.ldcmStatus == "No Error")
        #expect(decoded.pdHardResetCount == 0)
        #expect(decoded.pdShortDetectCount == 0)
        #expect(decoded.pdRoleSwapFailCount == 0)
        #expect(decoded.pdI2cErrorCount == 0)
        #expect(decoded.pdAttachCount == 0)
        #expect(decoded.pdDetachCount == 0)
    }

    @Test("A payload saved before the attach/detach fields existed decodes with zeros")
    func decodingPrePDAttachDetachPayloadDefaultsToZero() throws {
        // Shape persisted between the hard-reset/short-detect/role-swap/I2C
        // fields landing and the attach/detach fields landing after them.
        let midPayloadJSON = """
        {
            "overcurrentCount": 1,
            "linkErrorCount": 0,
            "enumerationFailureCount": 0,
            "addressFailureCount": 0,
            "ldcmStatus": "",
            "pdHardResetCount": 5,
            "pdShortDetectCount": 6,
            "pdRoleSwapFailCount": 7,
            "pdI2cErrorCount": 8
        }
        """
        let decoded = try JSONDecoder().decode(AcknowledgedCounters.self, from: Data(midPayloadJSON.utf8))

        #expect(decoded.pdHardResetCount == 5)
        #expect(decoded.pdShortDetectCount == 6)
        #expect(decoded.pdRoleSwapFailCount == 7)
        #expect(decoded.pdI2cErrorCount == 8)
        #expect(decoded.pdAttachCount == 0)
        #expect(decoded.pdDetachCount == 0)
    }

    @Test("A payload with every field round-trips through encode/decode")
    func roundTripsWithAllFields() throws {
        let original = AcknowledgedCounters(
            overcurrentCount: 1,
            linkErrorCount: 2,
            enumerationFailureCount: 3,
            addressFailureCount: 4,
            ldcmStatus: "Overvoltage",
            pdHardResetCount: 5,
            pdShortDetectCount: 6,
            pdRoleSwapFailCount: 7,
            pdI2cErrorCount: 8,
            pdAttachCount: 9,
            pdDetachCount: 10,
            pdBaselined: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AcknowledgedCounters.self, from: data)
        #expect(decoded == original)
        #expect(decoded.pdBaselined == true)
    }

    @Test("A payload saved before the pdBaselined marker existed, but carrying PD keys, decodes as baselined")
    func decodingPreMarkerPayloadWithPDKeysDecodesBaselined() throws {
        // Shape persisted between the attach/detach fields landing (DAR-289
        // ship) and the pdBaselined marker landing after them (this fix).
        // The marker field did not exist in that build, so JSONEncoder never
        // wrote it, and the only code path in that build that ever touched
        // these PD fields was the explicit "Reset Health Counters" action
        // (auto-baseline did not exist yet). A marker-less payload carrying
        // any PD key can therefore only be an explicit reset, so it decodes
        // as already baselined: treating it as unbaselined would let the
        // very next PD-reporting snapshot silently overwrite that user's
        // explicit reset via auto-baseline.
        let preMarkerJSON = """
        {
            "overcurrentCount": 0,
            "linkErrorCount": 0,
            "enumerationFailureCount": 0,
            "addressFailureCount": 0,
            "ldcmStatus": "",
            "pdHardResetCount": 5,
            "pdShortDetectCount": 6,
            "pdRoleSwapFailCount": 7,
            "pdI2cErrorCount": 8,
            "pdAttachCount": 9,
            "pdDetachCount": 10
        }
        """
        let decoded = try JSONDecoder().decode(AcknowledgedCounters.self, from: Data(preMarkerJSON.utf8))

        #expect(decoded.pdBaselined == true)
        #expect(decoded.pdHardResetCount == 5)
        #expect(decoded.pdAttachCount == 9)
        #expect(decoded.pdDetachCount == 10)
    }

    @Test("A payload with no PD keys at all (pre-PD-fields shape) decodes pdBaselined false")
    func decodingPayloadWithNoPDKeysDecodesUnbaselined() throws {
        // The original pre-PD-fields shape (see decodingOldPayloadDefaultsPDFieldsToZero
        // above): no PD keys exist at all, so there is nothing that could
        // have been an explicit PD reset. Correctly "never baselined", which
        // lets FlightRecorder's auto-baseline fire the first time this
        // port's PD data is actually seen.
        let oldPayloadJSON = """
        {
            "overcurrentCount": 3,
            "linkErrorCount": 1,
            "enumerationFailureCount": 0,
            "addressFailureCount": 0,
            "ldcmStatus": "No Error"
        }
        """
        let decoded = try JSONDecoder().decode(AcknowledgedCounters.self, from: Data(oldPayloadJSON.utf8))

        #expect(decoded.pdBaselined == false)
    }
}
