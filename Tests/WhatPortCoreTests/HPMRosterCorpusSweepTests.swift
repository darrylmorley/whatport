import Foundation
import Testing
@testable import WhatPortIOKit

// Replays every machine in the probe corpus through the real HPMReader.parse.
//
// The roster is the authoritative port list the whole app hangs off, and until
// now it was only ever exercised against the Mac running the suite. These sweeps
// run it against ~780 machines spanning M1 to M5, A18 Pro and Intel, macOS 14
// to 27. Skips rather than fails when the corpus is absent: it lives in the
// sibling whatcable-app working copy and is not in git.
@Suite("HPM roster — customer probe sweep")
struct HPMRosterCorpusSweepTests {

    // The parse takes a UUID the walk read from a controller ancestor. Probe 01
    // records the port node but not its ancestor, so where probe 35 is present
    // the real UUID is joined in from there, and where it is not this stands in.
    // Its only job is to be non-empty, which is all the parse asks of it.
    private static let placeholderUUID = "00000000-0000-0000-0000-000000000000"

    private struct MachineResult {
        let name: String
        let chip: String
        let ports: [RawHPMPort]
        let blocks: Int
    }

    private static func sweep() -> [MachineResult] {
        ProbeCorpus.machines.compactMap { machine in
            guard let output = machine.probe("01_walk_pd_tree.json") else { return nil }
            let blocks = ProbeCorpus.accessoryBlocks(in: output)
            guard !blocks.isEmpty else { return nil }

            let uuidsByPort = machine.probe("35_hpm_port_uuid.json").map { rosterOutput in
                Dictionary(
                    ProbeCorpus.roster(in: rosterOutput).map { ("\($0.portType):\($0.portNumber)", $0.uuid) },
                    uniquingKeysWith: { first, _ in first }
                )
            } ?? [:]

            let ports = blocks.compactMap { block -> RawHPMPort? in
                let portType = block.properties["PortTypeDescription"] as? String ?? ""
                let key = "\(portType):\(block.portNumber ?? -1)"
                return HPMReader.parse(
                    properties: block.properties,
                    entryName: block.entryName,
                    portNumber: block.portNumber,
                    controllerUUID: uuidsByPort[key] ?? placeholderUUID
                )
            }

            return MachineResult(
                name: machine.name,
                chip: machine.chip("01_walk_pd_tree.json"),
                ports: ports,
                blocks: blocks.count
            )
        }
    }

    @Test("Every Apple Silicon machine yields a port roster", .enabled(if: ProbeCorpus.isAvailable))
    func everyAppleSiliconMachineYieldsPorts() throws {
        let results = Self.sweep()
        try #require(results.count > 500, "Expected the corpus, got \(results.count) machines")

        let appleSilicon = results.filter { $0.chip.hasPrefix("Apple") }
        try #require(!appleSilicon.isEmpty)

        let empty = appleSilicon.filter { $0.ports.isEmpty }.map(\.name)
        #expect(empty.isEmpty, "Apple Silicon machines with no ports: \(empty.prefix(5))")

        // Intel Macs publish no port-controller nodes at all. Asserted rather
        // than filtered out silently, so "the sweep found nothing anywhere"
        // cannot pass as "Intel is expected to be empty".
        let intel = results.filter { !$0.chip.hasPrefix("Apple") }
        #expect(intel.allSatisfy { $0.ports.isEmpty }, "Intel machines should yield no ports")
    }

    @Test("Every machine that recorded port blocks is actually swept", .enabled(if: ProbeCorpus.isAvailable))
    func everyMachineThatRecordedBlocksIsSwept() throws {
        // The sweeps build their machine list with compactMap, so a machine
        // whose probe stops parsing simply disappears from the run and the
        // count assertions still pass. That is the failure this whole exercise
        // exists to prevent, so the input is counted from the raw text: any
        // machine whose probe contains a block header must yield blocks.
        var recorded = 0
        var silentlyDropped: [String] = []

        for machine in ProbeCorpus.machines {
            guard let output = machine.probe("01_walk_pd_tree.json") else { continue }
            guard output.contains("=== IOAccessoryManager[") else { continue }
            recorded += 1
            if ProbeCorpus.accessoryBlocks(in: output).isEmpty {
                silentlyDropped.append(machine.name)
            }
        }

        try #require(recorded > 700, "Expected the corpus, got \(recorded) machines with blocks")
        #expect(silentlyDropped.isEmpty, "\(silentlyDropped.count) machines parsed to nothing: \(silentlyDropped.prefix(5))")

        // Same guard for the other two probes these sweeps depend on.
        var smcRecorded = 0, smcDropped: [String] = []
        var rosterRecorded = 0, rosterDropped: [String] = []
        for machine in ProbeCorpus.machines {
            if let output = machine.probe("34_smc_power_keys.json"), output.contains("raw=") {
                smcRecorded += 1
                if ProbeCorpus.smcKeys(in: output).isEmpty { smcDropped.append(machine.name) }
            }
            if let output = machine.probe("35_hpm_port_uuid.json"), output.contains("] Port-") {
                rosterRecorded += 1
                if ProbeCorpus.roster(in: output).isEmpty { rosterDropped.append(machine.name) }
            }
        }
        try #require(smcRecorded > 500, "Expected SMC dumps, got \(smcRecorded)")
        try #require(rosterRecorded > 400, "Expected rosters, got \(rosterRecorded)")
        #expect(smcDropped.isEmpty, "SMC dumps parsed to nothing: \(smcDropped.prefix(5))")
        #expect(rosterDropped.isEmpty, "Rosters parsed to nothing: \(rosterDropped.prefix(5))")
    }

    @Test("Two services on one connector collapse to one port", .enabled(if: ProbeCorpus.isAvailable))
    func twoServicesOnOneConnectorCollapse() throws {
        // Deduplication lives in the walk, not the parse, so replaying parse
        // per recorded service never reaches it: with dedup disabled entirely,
        // every other test here stays green. Feed the shared roster builder a
        // real machine's ports twice, which is what a registry publishing two
        // interface nodes for one connector would look like.
        var exercised = 0

        for machine in ProbeCorpus.machines.prefix(60) {
            guard let walk = machine.probe("01_walk_pd_tree.json") else { continue }
            let ports = ProbeCorpus.accessoryBlocks(in: walk).compactMap { block in
                HPMReader.parse(
                    properties: block.properties,
                    entryName: block.entryName,
                    portNumber: block.portNumber,
                    controllerUUID: Self.placeholderUUID
                )
            }
            guard ports.count > 1 else { continue }

            let once = HPMReader.roster(from: ports)
            let twice = HPMReader.roster(from: ports + ports)
            #expect(twice.count == once.count, "\(machine.name): duplicates survived")
            #expect(twice.map(\.portNumber) == once.map(\.portNumber))
            #expect(twice.map(\.portType) == once.map(\.portType))

            // And the order is stable, which matters because MagSafe and USB-C
            // can share a number and the input arrives in registry order.
            #expect(HPMReader.roster(from: ports.reversed()).map(\.portType) == once.map(\.portType))
            exercised += 1
        }

        try #require(exercised >= 1, "Expected to exercise dedup, did \(exercised)")
    }

    @Test("Only USB-C and MagSafe reach the roster", .enabled(if: ProbeCorpus.isAvailable))
    func onlyUSBCAndMagSafeReachTheRoster() throws {
        let results = Self.sweep()

        var accepted: Set<String> = []
        for result in results {
            for port in result.ports { accepted.insert(port.portType) }
        }
        #expect(accepted == ["USB-C", "MagSafe 3"], "Unexpected port types: \(accepted.sorted())")

        // The corpus contains HDMI and Inductive nodes under the same base
        // class, so the filter is doing real work here rather than never
        // meeting a case. The corpus is a moving target maintained in the
        // sibling whatcable-app checkout (other sessions add machines), so
        // these assert a floor, not a census pin: if a future corpus ever
        // stops containing either kind, this stops proving anything and
        // should be revisited.
        var rejectedTypes: [String: Int] = [:]
        for machine in ProbeCorpus.machines {
            guard let output = machine.probe("01_walk_pd_tree.json") else { continue }
            for block in ProbeCorpus.accessoryBlocks(in: output) {
                let type = block.properties["PortTypeDescription"] as? String ?? ""
                guard type != "USB-C", !type.hasPrefix("MagSafe") else { continue }
                rejectedTypes[type, default: 0] += 1
            }
        }
        #expect((rejectedTypes["HDMI"] ?? 0) >= 1, "Expected at least 1 HDMI node, got \(rejectedTypes["HDMI"] ?? 0)")
        #expect((rejectedTypes["Inductive"] ?? 0) >= 1, "Expected at least 1 Inductive node, got \(rejectedTypes["Inductive"] ?? 0)")
    }

    @Test("The roster matches the machine's own port list", .enabled(if: ProbeCorpus.isAvailable))
    func rosterMatchesTheProbesOwnPortList() throws {

        var compared = 0
        var mismatches: [String] = []

        for machine in ProbeCorpus.machines {
            guard let walk = machine.probe("01_walk_pd_tree.json"),
                  let rosterOutput = machine.probe("35_hpm_port_uuid.json") else { continue }

            let blocks = ProbeCorpus.accessoryBlocks(in: walk)
            guard !blocks.isEmpty else { continue }

            let expected = Set(ProbeCorpus.roster(in: rosterOutput).map { "\($0.portType):\($0.portNumber)" })
            guard !expected.isEmpty else { continue }

            let parsed = Set(blocks.compactMap { block -> String? in
                let port = HPMReader.parse(
                    properties: block.properties,
                    entryName: block.entryName,
                    portNumber: block.portNumber,
                    controllerUUID: Self.placeholderUUID
                )
                return port.map { "\($0.portType):\($0.portNumber)" }
            })

            compared += 1
            if parsed != expected {
                mismatches.append("\(machine.name): parsed \(parsed.sorted()) vs roster \(expected.sorted())")
            }
        }

        // Two independent probes, two independent code paths: probe 01 walks
        // IOAccessoryManager and probe 35 walks the HPM controllers. Agreement
        // between them is worth more than either agreeing with itself.
        try #require(compared > 400, "Expected to compare hundreds of machines, got \(compared)")
        #expect(mismatches.isEmpty, "Roster disagreements: \(mismatches.prefix(5))")
    }

    @Test("Every port carries a UUID and a positive number", .enabled(if: ProbeCorpus.isAvailable))
    func everyPortCarriesAUUIDAndPositiveNumber() throws {

        var checked = 0
        var bad: [String] = []

        for machine in ProbeCorpus.machines {
            guard let walk = machine.probe("01_walk_pd_tree.json"),
                  let rosterOutput = machine.probe("35_hpm_port_uuid.json") else { continue }

            let uuidsByPort = Dictionary(
                ProbeCorpus.roster(in: rosterOutput).map { ("\($0.portType):\($0.portNumber)", $0.uuid) },
                uniquingKeysWith: { first, _ in first }
            )
            guard !uuidsByPort.isEmpty else { continue }

            for block in ProbeCorpus.accessoryBlocks(in: walk) {
                let type = block.properties["PortTypeDescription"] as? String ?? ""
                let key = "\(type):\(block.portNumber ?? -1)"
                guard let realUUID = uuidsByPort[key] else { continue }

                guard let port = HPMReader.parse(
                    properties: block.properties,
                    entryName: block.entryName,
                    portNumber: block.portNumber,
                    controllerUUID: realUUID
                ) else {
                    bad.append("\(machine.name) \(key): rejected a port the roster lists")
                    continue
                }

                checked += 1
                if port.uuid != realUUID { bad.append("\(machine.name) \(key): UUID did not round-trip") }
                if port.portNumber <= 0 { bad.append("\(machine.name) \(key): port number \(port.portNumber)") }

                // The UUID is the join key every other subsystem uses, so a port
                // without one is worse than no port. Checking that the parse
                // rejects it needs a port with no UUID, which the corpus never
                // contains, so take a real one and withhold it.
                let withoutUUID = HPMReader.parse(
                    properties: block.properties,
                    entryName: block.entryName,
                    portNumber: block.portNumber,
                    controllerUUID: nil
                )
                if withoutUUID != nil { bad.append("\(machine.name) \(key): accepted a port with no UUID") }
            }
        }

        try #require(checked > 1000, "Expected over a thousand ports, got \(checked)")
        #expect(bad.isEmpty, "\(bad.count) bad ports, first few: \(bad.prefix(5))")
    }

    @Test("A port that is not built in is rejected", .enabled(if: ProbeCorpus.isAvailable))
    func aPortThatIsNotBuiltInIsRejected() throws {

        // Every machine in the corpus publishes BuiltIn = true, so the rejecting
        // branch has no natural case to exercise. Take a real port's properties
        // and flip the one key, which tests the rule without inventing a port.
        var flipped = 0
        for machine in ProbeCorpus.machines.prefix(50) {
            guard let walk = machine.probe("01_walk_pd_tree.json") else { continue }
            for block in ProbeCorpus.accessoryBlocks(in: walk) {
                let type = block.properties["PortTypeDescription"] as? String ?? ""
                guard type == "USB-C" || type.hasPrefix("MagSafe") else { continue }
                #expect(block.properties["BuiltIn"] as? Bool == true, "\(machine.name) should publish BuiltIn")

                var external = block.properties
                external["BuiltIn"] = false
                let port = HPMReader.parse(
                    properties: external,
                    entryName: block.entryName,
                    portNumber: block.portNumber,
                    controllerUUID: Self.placeholderUUID
                )
                #expect(port == nil, "\(machine.name): a port marked not built in should be rejected")
                flipped += 1
            }
        }
        try #require(flipped > 0, "Expected to exercise the BuiltIn rule")
    }
}
