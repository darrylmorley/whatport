import Foundation
import Testing
@testable import WhatPortCore

// Replays the Intel machines in the customer-probe corpus through the real
// PortManager pipeline (DAR-291, design section 6).
//
// The unit tests in PortManagerTests pin the tier logic against synthetic
// inputs: they prove the branches are wired correctly, not that real Intel
// hardware produces the roster the design predicts. Nobody on the team has an
// Intel Mac, so the corpus is the only Intel evidence there is, and this sweep
// is the thing standing between "reduced mode works" and "reduced mode is a
// plausible story".
//
// The claims under test, all from research/dar-291-intel-design.md:
//   - IOThunderboltPort Socket IDs are present on Intel and give a roster
//   - that roster lands the machine in .thunderboltOnly, not .full or .none
//   - no port acquires pdReliability, because the ordinal join is gated off
//   - no port acquires per-port SMC power, because DxUI (the join key) is absent
//
// Skips when the corpus is absent (sibling working copy, not in git).
@Suite("Intel reduced-capability mode — customer probe sweep")
struct IntelReducedModeCorpusSweepTests {

    private struct IntelMachine {
        let name: String
        let chip: String
        let sockets: [Int]
        let portControllerEntries: Int
        let smcChannelsWithJoinKey: Int
        let thunderboltControllers: Int
    }

    // Probe 27 lists each matched service as "[0] IOThunderboltController…" or
    // "[0] IOThunderboltControllerType4…". Counted by distinct index within the
    // section, since every controller contributes several lines.
    private static func thunderboltControllerCount(in output: String) -> Int {
        guard let start = output.range(of: "=== IOThunderboltController ===") else { return 0 }
        let rest = output[start.upperBound...]
        let section = rest.range(of: "\n=== ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)

        var indices = Set<Int>()
        for line in section.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]"),
                  trimmed[trimmed.index(after: close)...].contains("IOThunderboltController"),
                  let index = Int(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            else { continue }
            indices.insert(index)
        }
        return indices.count
    }

    // Socket ID on IOThunderboltPort is published as a quoted string on Intel
    // ("Socket ID = \"2\""), where Apple Silicon publishes a bare integer.
    // ProbeCorpus.thunderboltBlocks already normalises this, so the roster is
    // read through the same parser the app uses rather than a private regex.
    private static func sockets(in output: String) -> [Int] {
        let ids = ProbeCorpus.thunderboltBlocks(in: output).compactMap { block -> Int? in
            if let int = block["Socket ID"] as? Int { return int }
            if let string = block["Socket ID"] as? String { return Int(string) }
            return nil
        }
        return Array(Set(ids)).sorted()
    }

    private static func sweep() -> [IntelMachine] {
        ProbeCorpus.machines.compactMap { machine -> IntelMachine? in
            // The corpus records the CPU string; Apple Silicon entries start
            // "Apple". Same partition the HPM roster sweep uses.
            let chip = machine.chip("29_usb4_router_interfaces.json")
            guard !chip.isEmpty, !chip.hasPrefix("Apple") else { return nil }
            guard let tbOutput = machine.probe("29_usb4_router_interfaces.json") else { return nil }

            let entries: Int = machine.probe("32_smart_battery_full_keys.json")
                .map { ProbeCorpus.portControllerEntries(inFullOutput: $0).count } ?? 0

            // The per-port SMC join key is DxUI, where x is the D-channel
            // index. Matched exactly: other SMC keys end in "UI" (EPUI turns
            // up on four Intel machines here) and would otherwise read as a
            // join key that does not exist.
            let joinKeys: Int = machine.probe("34_smc_power_keys.json").map { smcOutput in
                ProbeCorpus.smcKeys(in: smcOutput).keys.filter { key in
                    key.count == 4 && key.hasPrefix("D") && key.hasSuffix("UI")
                        && key[key.index(key.startIndex, offsetBy: 1)].isNumber
                }.count
            } ?? 0

            let controllers: Int = machine.probe("27_iopower_management.json")
                .map { Self.thunderboltControllerCount(in: $0) } ?? 0

            return IntelMachine(
                name: machine.name,
                chip: chip,
                sockets: Self.sockets(in: tbOutput),
                portControllerEntries: entries,
                smcChannelsWithJoinKey: joinKeys,
                thunderboltControllers: controllers
            )
        }
    }

    // Guards the sweep itself rather than the feature. It is a change
    // detector, not proof: the expected set is derived with the same two
    // guards sweep() uses, so today it cannot fail. It earns its place by
    // failing if someone later adds a filter to one and not the other, which
    // is how a sweep quietly stops covering half the corpus.
    @Test("Every Intel machine carrying probe 29 is actually swept", .enabled(if: ProbeCorpus.isAvailable))
    func everyIntelMachineIsSwept() throws {
        var expected: [String] = []
        for machine in ProbeCorpus.machines {
            let chip = machine.chip("29_usb4_router_interfaces.json")
            guard !chip.isEmpty, !chip.hasPrefix("Apple") else { continue }
            guard machine.probe("29_usb4_router_interfaces.json") != nil else { continue }
            expected.append(machine.name)
        }

        try #require(expected.count >= 78, "Intel slice shrank unexpectedly: \(expected.count)")

        let swept = Set(Self.sweep().map(\.name))
        let dropped = expected.filter { !swept.contains($0) }
        #expect(dropped.isEmpty, "Machines silently dropped by the sweep: \(dropped.prefix(5))")
    }

    @Test("Intel machines are rostered from Thunderbolt socket IDs", .enabled(if: ProbeCorpus.isAvailable))
    func intelMachinesAreRosteredFromSocketIDs() throws {
        let machines = Self.sweep()
        try #require(machines.count >= 78, "Expected the Intel slice of the corpus, got \(machines.count)")

        let rostered = machines.filter { !$0.sockets.isEmpty }
        try #require(!rostered.isEmpty, "No Intel machine yielded a socket roster")

        // Socket IDs are 1-based and contiguous per machine, in the clusters
        // the design predicted: 2-port and 4-port portables, and the 2019 Mac
        // Pro at 5-8. A machine outside these shapes means the socket
        // numbering assumption is wrong somewhere.
        var oddShapes: [String] = []
        for machine in rostered {
            let expectedTwo = machine.sockets == [1, 2]
            let expectedFour = machine.sockets == [1, 2, 3, 4]
            let expectedMacPro = machine.sockets == [5, 6, 7, 8]
            if !(expectedTwo || expectedFour || expectedMacPro) {
                oddShapes.append("\(machine.name): \(machine.sockets)")
            }
        }
        #expect(oddShapes.isEmpty, "Unexpected socket shapes: \(oddShapes.prefix(5))")

        let twoPort = rostered.filter { $0.sockets.count == 2 }.count
        let fourPort = rostered.filter { $0.sockets.count == 4 }.count
        #expect(twoPort > 10, "Expected a 2-port cluster, got \(twoPort)")
        #expect(fourPort > 30, "Expected a 4-port cluster, got \(fourPort)")
    }

    @Test("A socket roster puts the machine in reduced mode, never full", .enabled(if: ProbeCorpus.isAvailable))
    func socketRosterYieldsThunderboltOnlyTier() throws {
        let machines = Self.sweep().filter { !$0.sockets.isEmpty }
        try #require(!machines.isEmpty)

        var wrongTier: [String] = []
        var wrongPortCount: [String] = []

        for machine in machines {
            let manager = PortManager()
            manager.applySnapshot(PortManagerSnapshot(
                tbData: machine.sockets.map { ThunderboltInput(socketID: $0) }
            ))

            if manager.portDataTier != .thunderboltOnly {
                wrongTier.append("\(machine.name): \(manager.portDataTier)")
            }
            if manager.ports.count != machine.sockets.count {
                wrongPortCount.append("\(machine.name): \(manager.ports.count) != \(machine.sockets.count)")
            }
        }

        #expect(wrongTier.isEmpty, "\(wrongTier.prefix(5))")
        #expect(wrongPortCount.isEmpty, "\(wrongPortCount.prefix(5))")
    }

    @Test("PD reliability never attaches without an HPM roster", .enabled(if: ProbeCorpus.isAvailable))
    func pdReliabilityIsGatedOffOnIntel() throws {
        // The gate matters precisely because Intel *does* publish
        // PortControllerInfo: feeding it in and getting nothing back is the
        // assertion. A machine with entries but no roster would silently take
        // the ordinal join if the gate regressed.
        let machines = Self.sweep().filter { !$0.sockets.isEmpty && $0.portControllerEntries > 0 }
        try #require(!machines.isEmpty, "Expected Intel machines publishing PortControllerInfo")

        var leaked: [String] = []
        for machine in machines {
            let manager = PortManager()
            manager.applySnapshot(PortManagerSnapshot(
                tbData: machine.sockets.map { ThunderboltInput(socketID: $0) },
                pdReliabilityData: (0..<machine.portControllerEntries).map {
                    PDReliabilityInput(entryOffset: $0, attachCount: 42)
                }
            ))

            let withCounters = manager.ports.filter { $0.pdReliability != nil }
            if !withCounters.isEmpty {
                leaked.append("\(machine.name): \(withCounters.count) ports took PD counters")
            }
        }

        #expect(leaked.isEmpty, "\(leaked.prefix(5))")
    }

    @Test("Per-port SMC power has no join key on Intel", .enabled(if: ProbeCorpus.isAvailable))
    func perPortSMCPowerHasNoJoinKeyOnIntel() throws {
        let machines = Self.sweep()
        let withSMC = machines.filter { $0.smcChannelsWithJoinKey > 0 }
        // DxUI is the only key that joins a D-channel to a port. Its absence
        // across the Intel corpus is what keeps per-port SMC power switched
        // off there, rather than any explicit arch check in the reader.
        #expect(withSMC.isEmpty, "Intel machines publishing a DxUI join key: \(withSMC.map(\.name).prefix(5))")
    }

    // Documents, rather than hides, the Intel machines that publish no
    // IOThunderboltPort at all. The count is pinned: if it grows, reduced mode
    // is failing on more hardware than this sweep was written against.
    //
    // They split two ways, and the empty state must not say the same thing to
    // both: most have no Thunderbolt controller either (pre-Thunderbolt Macs
    // on patched macOS), where "no ports" is simply true. One has a controller
    // that publishes nothing, where it would be a false claim.
    @Test("Intel machines with no Thunderbolt roster are accounted for", .enabled(if: ProbeCorpus.isAvailable))
    func machinesWithoutASocketRosterAreAccountedFor() throws {
        let machines = Self.sweep()
        try #require(!machines.isEmpty)

        // These two counts are fitted to the corpus as it stands (4 unrostered,
        // exactly 1 of them with a live controller), not derived bounds. They
        // are canaries on purpose. If one trips after new captures land, it
        // means a machine shape nobody has looked at yet has arrived: go read
        // the new capture and decide whether reduced mode handles it, then
        // move the number. It does not mean the test is flaky.
        let unrostered = machines.filter { $0.sockets.isEmpty }
        #expect(
            unrostered.count <= 4,
            "More Intel machines than expected publish no Thunderbolt ports: \(unrostered.map(\.name))"
        )

        var wrongClaim: [String] = []
        for machine in unrostered {
            let manager = PortManager()
            manager.applySnapshot(PortManagerSnapshot(
                controllerPower: ControllerPowerInput(
                    anyThunderboltControllerAwake: machine.thunderboltControllers > 0 ? true : nil,
                    anyXHCIControllerAwake: nil,
                    thunderboltControllerCount: machine.thunderboltControllers
                )
            ))

            #expect(manager.portDataTier == .none, "\(machine.name)")

            let expectSilent = machine.thunderboltControllers > 0
            if manager.thunderboltControllerPresentButSilent != expectSilent {
                wrongClaim.append("\(machine.name): controllers=\(machine.thunderboltControllers)")
            }
        }
        #expect(wrongClaim.isEmpty, "\(wrongClaim)")

        // The split itself is the point: if every unrostered machine turned out
        // to have no controller, the softened wording would be dead code.
        let withController = unrostered.filter { $0.thunderboltControllers > 0 }
        #expect(
            withController.count == 1,
            "Expected exactly the i9-10885H outlier, got \(withController.map(\.name))"
        )
    }

    // The inverse guard: a controller that does publish ports must never be
    // read as silent, or every healthy Intel Mac would get the softer wording.
    @Test("A rostered Intel machine is never treated as silent", .enabled(if: ProbeCorpus.isAvailable))
    func rosteredMachinesAreNeverSilent() throws {
        let machines = Self.sweep().filter { !$0.sockets.isEmpty }
        try #require(!machines.isEmpty)

        var misread: [String] = []
        for machine in machines {
            let manager = PortManager()
            manager.applySnapshot(PortManagerSnapshot(
                tbData: machine.sockets.map { ThunderboltInput(socketID: $0) },
                controllerPower: ControllerPowerInput(
                    anyThunderboltControllerAwake: true,
                    anyXHCIControllerAwake: nil,
                    thunderboltControllerCount: max(machine.thunderboltControllers, 1)
                )
            ))
            if manager.thunderboltControllerPresentButSilent {
                misread.append(machine.name)
            }
        }
        #expect(misread.isEmpty, "\(misread.prefix(5))")
    }
}
