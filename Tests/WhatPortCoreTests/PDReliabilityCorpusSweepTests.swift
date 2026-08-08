import Foundation
import Testing
import WhatPortCore
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

    // MARK: - Keyed UUID cross-check (DAR-324)
    //
    // Replays the full three-probe chain PortManager.crossCheckPDJoin relies
    // on at runtime: PortControllerInfo entries (probe 32), SMC D-channel
    // UUIDs (probe 34), and the HPM port roster (probe 35). Where every step
    // resolves, this checks the keyed route (entry offset j <-> D-channel
    // j+1, channel UUID = HPM UUID) against the ordinal rule the join
    // trusts by default. This does not exercise crossCheckPDJoin itself
    // (that's PortManagerTests, with hand-built fixtures) -- it is the
    // real-world evidence the ordinal rule holds wherever both routes
    // resolve, which is what justifies trusting it when the keyed route
    // does not.
    private struct KeyedChainMachine {
        let name: String
        // USB-C ports from the probe-35 roster, ascending by port number:
        // the same roster the ordinal join sorts.
        let usbCPortsAscending: [Int]
        // entryOffset -> USB-C port number, only for offsets whose D-channel
        // (offset + 1) resolves unambiguously to a roster USB-C port.
        let resolvedByOffset: [Int: Int]
    }

    private static func keyedChainMachines() -> [KeyedChainMachine] {
        ProbeCorpus.machines.compactMap { machine -> KeyedChainMachine? in
            guard let batteryOutput = machine.probe("32_smart_battery_full_keys.json"),
                  let section = ProbeCorpus.isolatedSmartBatterySection(inFullOutput: batteryOutput) else { return nil }
            let entries = ProbeCorpus.portControllerEntries(in: section)
            guard !entries.isEmpty else { return nil }

            guard let smcOutput = machine.probe("34_smc_power_keys.json") else { return nil }
            let smcKeys = ProbeCorpus.smcKeys(in: smcOutput)
            guard !smcKeys.isEmpty else { return nil }

            guard let rosterOutput = machine.probe("35_hpm_port_uuid.json") else { return nil }
            let usbCPorts = ProbeCorpus.roster(in: rosterOutput).filter { $0.portType == "USB-C" }
            guard !usbCPorts.isEmpty else { return nil }

            // Normalised HPM UUID -> USB-C port numbers. Kept as an array per
            // UUID, matching crossCheckPDJoin's own ambiguity handling: two
            // ports sharing a UUID resolve to neither.
            var portNumbersByUUID: [String: [Int]] = [:]
            for port in usbCPorts {
                portNumbersByUUID[SMCContractAttribution.normalisedUUID(port.uuid), default: []].append(port.portNumber)
            }

            // The real channel builder: D1..D4 only, dropping all-zero UUIDs,
            // exactly what production's SMC reader (and PortManager's cross-
            // check, fed from it) ever sees.
            let channels = SMCPowerReader.buildPortPowerChannels(readKey: { smcKeys[$0] })
            let channelsByIndex = Dictionary(channels.map { ($0.channel, $0) }, uniquingKeysWith: { first, _ in first })

            var resolvedByOffset: [Int: Int] = [:]
            for entry in entries {
                let channelIndex = entry.index + 1
                guard let channel = channelsByIndex[channelIndex] else { continue }
                guard let matches = portNumbersByUUID[channel.uuid], matches.count == 1 else { continue }
                resolvedByOffset[entry.index] = matches[0]
            }

            let usbCPortsAscending = Array(Set(usbCPorts.map(\.portNumber))).sorted()
            return KeyedChainMachine(
                name: machine.name,
                usbCPortsAscending: usbCPortsAscending,
                resolvedByOffset: resolvedByOffset
            )
        }
    }

    @Test(
        "Keyed cross-check agrees with the ordinal join wherever the UUID chain resolves",
        .enabled(if: ProbeCorpus.isAvailable)
    )
    func keyedCrossCheckAgreesWithOrdinalJoin() throws {
        let machines = Self.keyedChainMachines()

        // Fully resolvable: the chain (PortControllerInfo -> SMC D-channel
        // UUID -> HPM roster) settles a USB-C port for every offset the
        // ordinal join would consume (0..<usbCCount). The MagSafe
        // controller has no D-channel of its own (see SMCPowerReader), so a
        // trailing MagSafe entry is never in that range and never affects
        // this.
        let fullyResolvable = machines.filter { machine in
            let usbCCount = machine.usbCPortsAscending.count
            return (0..<usbCCount).allSatisfy { machine.resolvedByOffset[$0] != nil }
        }

        // Corpus observed on this sweep: 495/501 candidate machines (every
        // machine with a non-empty PortControllerInfo, SMC key dump, and
        // HPM roster) fully resolve the chain, zero disagreements. That is
        // a larger sample than the 97 machines an earlier, smaller corpus
        // snapshot found -- the corpus has grown since -- so the floor is
        // set well below both figures, and should not need raising as the
        // corpus continues to grow or shrink slightly.
        try #require(
            fullyResolvable.count >= 80,
            "Expected >= 80 fully-resolvable machines, got \(fullyResolvable.count)"
        )

        var disagreements: [String] = []
        for machine in fullyResolvable {
            // Bounded to the offsets production actually consumes
            // (0..<usbCPortsAscending.count): a trailing PD entry (the
            // MagSafe tail) can resolve through an extra D-channel, and
            // indexing usbCPortsAscending with that offset would be out of
            // bounds. crossCheckPDJoin never looks past this range either
            // (the ordinal join only ever attributes offsets in it).
            for (offset, keyedPort) in machine.resolvedByOffset where offset < machine.usbCPortsAscending.count {
                let ordinalPort = machine.usbCPortsAscending[offset]
                if keyedPort != ordinalPort {
                    disagreements.append("\(machine.name) offset \(offset): keyed=\(keyedPort) ordinal=\(ordinalPort)")
                }
            }
        }

        // A failure here means a real machine violates the ordinal ordering
        // assumption joinPDReliabilityOrdinally (and the keyed cross-check
        // built on top of it) depends on, and PD attribution on that
        // hardware must be investigated before it is trusted again. This is
        // a deliberate invariant, not a census pin: it is not expected to
        // ever fail, and a failure is a real finding, not noise to raise the
        // floor past.
        #expect(disagreements.isEmpty, "\(disagreements.count) disagreements: \(disagreements.prefix(5))")
    }
}
