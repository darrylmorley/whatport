import Foundation
import Testing
@testable import WhatPortIOKit

// Replays recorded IOThunderboltPort adapters through the real
// ThunderboltReader.parse.
//
// This reader is the direct cause of the false failure that started DAR-222:
// a live smoke test asserted every adapter carries a Socket ID, which stops
// being true the moment a Thunderbolt device is attached, because the
// downstream switch contributes adapters of its own. The corpus contains both
// shapes in quantity, so the rule can be pinned against machines with docks
// attached rather than against whatever is plugged into this one.
//
// Skips when the corpus is absent (sibling working copy, not in git).
@Suite("Thunderbolt adapters — customer probe sweep")
struct ThunderboltCorpusSweepTests {

    private struct MachineAdapters {
        let name: String
        let blocks: [[String: Any]]
        let parsed: [RawThunderboltData]
    }

    private static func sweep() -> [MachineAdapters] {
        ProbeCorpus.machines.compactMap { machine -> MachineAdapters? in
            guard let output = machine.probe("29_usb4_router_interfaces.json") else { return nil }
            let blocks = ProbeCorpus.thunderboltBlocks(in: output)
            guard !blocks.isEmpty else { return nil }
            return MachineAdapters(
                name: machine.name,
                blocks: blocks,
                parsed: blocks.compactMap { ThunderboltReader.parse(properties: $0) }
            )
        }
    }

    @Test("Every machine's adapters parse, and only physical ports survive", .enabled(if: ProbeCorpus.isAvailable))
    func onlyPhysicalPortsSurvive() throws {
        let machines = Self.sweep()
        try #require(machines.count > 300, "Expected hundreds of machines, got \(machines.count)")

        var totalBlocks = 0
        var kept = 0
        var wrongDescription: [String] = []

        for machine in machines {
            totalBlocks += machine.blocks.count
            kept += machine.parsed.count

            for port in machine.parsed where port.description != "Thunderbolt Port" {
                wrongDescription.append("\(machine.name): kept \(port.description)")
            }
        }

        try #require(totalBlocks > 2000, "Expected thousands of adapters, got \(totalBlocks)")
        #expect(wrongDescription.isEmpty, "\(wrongDescription.prefix(5))")

        // The filter must be doing real work: the corpus is full of NHI, PCIe
        // and DisplayPort adapters that are not physical ports. If everything
        // started surviving, the reader would be reporting adapters as ports.
        #expect(kept < totalBlocks, "Every adapter survived the filter, which cannot be right")
        #expect(kept > 0)
    }

    @Test("Socket IDs land on the machine's own roster", .enabled(if: ProbeCorpus.isAvailable))
    func socketIDsLandOnTheRoster() throws {
        var checked = 0
        var offRoster: [String] = []

        for machine in ProbeCorpus.machines {
            guard let tb = machine.probe("29_usb4_router_interfaces.json"),
                  let rosterOutput = machine.probe("35_hpm_port_uuid.json") else { continue }

            let usbCPorts = Set(
                ProbeCorpus.roster(in: rosterOutput)
                    .filter { $0.portType == "USB-C" }
                    .map(\.portNumber)
            )
            guard !usbCPorts.isEmpty else { continue }

            for port in ProbeCorpus.thunderboltBlocks(in: tb).compactMap({ ThunderboltReader.parse(properties: $0) }) {
                // A socket-less adapter belongs to an attached device's switch,
                // not to this Mac. That is the case the old smoke test got
                // wrong, so it is expected here rather than treated as a fault.
                guard !port.socketID.isEmpty, let socket = Int(port.socketID) else { continue }
                checked += 1
                if !usbCPorts.contains(socket) {
                    offRoster.append("\(machine.name): socket \(socket), roster \(usbCPorts.sorted())")
                }
            }
        }

        // The socket ID is used directly as a physical port number, so one that
        // is not on the roster would put a Thunderbolt link on a card that does
        // not exist, or on the wrong one.
        try #require(checked > 500, "Expected hundreds of host adapters, got \(checked)")
        #expect(offRoster.isEmpty, "\(offRoster.count) off-roster sockets: \(offRoster.prefix(5))")
    }

    @Test("Adapters without a Socket ID are common, so nothing may require one", .enabled(if: ProbeCorpus.isAvailable))
    func adaptersWithoutASocketIDAreCommon() throws {
        var withSocket = 0
        var withoutSocket = 0
        var machinesWithBoth = 0

        for machine in Self.sweep() {
            let sockets = machine.parsed.map(\.socketID)
            let missing = sockets.filter(\.isEmpty).count
            withSocket += sockets.count - missing
            withoutSocket += missing
            if missing > 0 && missing < sockets.count { machinesWithBoth += 1 }
        }

        // This is the shape that made PR #80 go red on a change that never
        // touched IOKit. Pinned so nobody reintroduces "every adapter has a
        // Socket ID" as an invariant: on this corpus it is false on hundreds of
        // machines, which is simply what a plugged-in dock looks like.
        try #require(withSocket > 500, "Expected host adapters with sockets, got \(withSocket)")
        #expect(withoutSocket > 100, "Expected socket-less adapters, got \(withoutSocket)")
        #expect(machinesWithBoth > 50, "Expected machines carrying both, got \(machinesWithBoth)")
    }

    @Test("An adapter is active only when width and speed are both non-zero", .enabled(if: ProbeCorpus.isAvailable))
    func activeRequiresWidthAndSpeed() throws {
        var active = 0
        var idle = 0
        var wrong: [String] = []

        for machine in Self.sweep() {
            for port in machine.parsed {
                let expected = port.currentLinkWidth > 0 && port.currentLinkSpeed > 0
                if port.isActive != expected {
                    wrong.append("\(machine.name): w\(port.currentLinkWidth) s\(port.currentLinkSpeed)")
                }
                if port.isActive { active += 1 } else { idle += 1 }
            }
        }

        // Both sides must occur, or the rule is only ever tested one way.
        #expect(wrong.isEmpty, "\(wrong.prefix(5))")
        #expect(active > 100, "Expected active links in the corpus, got \(active)")
        #expect(idle > 100, "Expected idle links in the corpus, got \(idle)")
    }
}
