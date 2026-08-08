import Foundation
import Testing
@testable import WhatPortIOKit

// Replays recorded AppleSmartBattery dumps (probe 32) through the real
// PDReliabilityReader.parse, to check the field extraction it relies on and
// the length invariant the ordinal join in PortManager.correlate depends on:
// PortControllerInfo carries no port identifier of its own, only array
// order, and on every corpus machine that publishes both arrays,
// PortControllerInfo and FedDetails (which IS content-addressable, one entry
// per USB-C port) have identical lengths. This suite does not exercise the
// join itself (it has no USB-C port roster to join against) -- see
// PortManagerTests for that, including the non-contiguous-port-numbering
// case the ordinal rule exists for.
//
// Skips when the corpus is absent (it lives in the sibling whatcable-app
// working copy and is not in git).
@Suite("PD reliability — customer probe sweep")
struct PDReliabilityCorpusSweepTests {

    private struct MachineEntries {
        let name: String
        // The real reader's output, built from dictionaries keyed by the same
        // literal key names ProbeCorpus's own text parser extracted, so a
        // key-name mismatch between the two files shows up as an all-zero
        // field here rather than silently agreeing with itself.
        let parsed: [RawPDReliability]
        let declaredPortControllerLength: Int?
        let declaredFedDetailsLength: Int?
    }

    // Loads and parses every machine's probe 32 capture, via ProbeCorpus's
    // own truncation-drop and AppleSmartBatteryManager-cut helper (the same
    // one production-shaped callers use, so the rule lives in one place),
    // then replays each entry through PDReliabilityReader.parse (the same
    // function the registry walk calls per PortControllerInfo entry).
    private static func machinesWithEntries() -> [MachineEntries] {
        ProbeCorpus.machines.compactMap { machine -> MachineEntries? in
            guard let output = machine.probe("32_smart_battery_full_keys.json") else { return nil }
            guard let section = ProbeCorpus.isolatedSmartBatterySection(inFullOutput: output) else { return nil }

            let entries = ProbeCorpus.portControllerEntries(in: section)
            let parsed = entries.map { entry in
                PDReliabilityReader.parse(
                    entry: [
                        "PortControllerAttachCount": entry.attachCount,
                        "PortControllerDetachCount": entry.detachCount,
                        "PortControllerHardResetCount": entry.hardResetCount,
                        "PortControllerIrqCntHrdRst": entry.irqHardResetCount,
                        "PortControllerShortDetectCount": entry.shortDetectCount,
                        "PortControllerDataRoleSwapFailCount": entry.dataRoleSwapFailCount,
                        "PortControllerPwrRoleSwapFailCount": entry.powerRoleSwapFailCount,
                        "PortControllerI2cErrCount": entry.i2cErrorCount,
                    ],
                    entryOffset: entry.index
                )
            }

            return MachineEntries(
                name: machine.name,
                parsed: parsed,
                declaredPortControllerLength: ProbeCorpus.declaredArrayLength(ofKey: "PortControllerInfo", in: section),
                declaredFedDetailsLength: ProbeCorpus.declaredArrayLength(ofKey: "FedDetails", in: section)
            )
        }
    }

    @Test("Hundreds of corpus machines publish PortControllerInfo", .enabled(if: ProbeCorpus.isAvailable))
    func machinesPublishPortControllerInfo() throws {
        let machines = Self.machinesWithEntries().filter { !$0.parsed.isEmpty }
        // Corpus observed: 727 machines. Floor set well below that so the
        // test does not regress as the corpus grows or changes shape.
        try #require(machines.count >= 500, "Expected hundreds of machines publishing PortControllerInfo, got \(machines.count)")
    }

    @Test(
        "PortControllerInfo and FedDetails agree on length wherever both are published",
        .enabled(if: ProbeCorpus.isAvailable)
    )
    func portControllerInfoAndFedDetailsLengthsAgree() throws {
        let machines = Self.machinesWithEntries().filter {
            guard let pci = $0.declaredPortControllerLength, let fed = $0.declaredFedDetailsLength else { return false }
            return pci > 0 || fed > 0
        }
        try #require(machines.count > 200, "Expected hundreds of machines with both arrays, got \(machines.count)")

        let agreeing = machines.filter { $0.declaredPortControllerLength == $0.declaredFedDetailsLength }

        // Corpus observed: 661/661 (ratio 1.0). Floor at 0.99 so a handful of
        // future oddities don't fail the whole suite, while still catching a
        // real regression in the join assumption.
        let ratio = Double(agreeing.count) / Double(machines.count)
        #expect(ratio >= 0.99, "Only \(agreeing.count)/\(machines.count) machines have matching array lengths (ratio \(ratio))")
    }

    @Test(
        "Hundreds of corpus machines report a non-zero PortControllerIrqCntHrdRst",
        .enabled(if: ProbeCorpus.isAvailable)
    )
    func machinesReportNonZeroIrqHardReset() throws {
        let machines = Self.machinesWithEntries().filter { machine in
            machine.parsed.contains { $0.irqHardResetCount > 0 }
        }
        // Corpus observed: 225 machines. Floor set below that.
        try #require(machines.count >= 150, "Expected machines with a non-zero PortControllerIrqCntHrdRst, got \(machines.count)")
    }

    // entryOffset is a 0-based array position, not a port number (see
    // PDReliabilityReader): a plausible range is 0..<8, matching the same
    // "at most 8 port controllers" ceiling the old 1...8 port-number check
    // used, just shifted for the 0-based offset.
    @Test("Every parsed entry has a plausible array offset (0..<8)", .enabled(if: ProbeCorpus.isAvailable))
    func everyEntryHasAPlausibleOffset() throws {
        let machines = Self.machinesWithEntries()
        try #require(!machines.isEmpty, "Expected the corpus to be available")

        var totalEntries = 0
        var outOfRange: [String] = []

        for machine in machines {
            for entry in machine.parsed {
                totalEntries += 1
                if !(0..<8).contains(entry.entryOffset) {
                    outOfRange.append("\(machine.name): offset \(entry.entryOffset)")
                }
            }
        }

        try #require(totalEntries > 500, "Expected hundreds of entries to check, got \(totalEntries)")
        #expect(outOfRange.isEmpty, "\(outOfRange.count) entries out of the plausible 0..<8 range: \(outOfRange.prefix(5))")
    }
}
