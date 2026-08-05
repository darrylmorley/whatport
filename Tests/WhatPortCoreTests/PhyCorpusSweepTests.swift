import Foundation
import Testing
@testable import WhatPortIOKit

// Replays recorded AppleTypeCPhy services through the real PhyReader.parse.
//
// This sweep exists because of a mistake worth recording. It was written down
// as fact that the corpus could not cover this reader, on the evidence of probe
// 31, which flattens nested dictionaries and so loses the entire lane map.
// Probe 01 records the same services with the lane map intact, on 168 machines.
// The reason that went unnoticed is that this file's own loader used to skip
// nested dictionaries, so the data was invisible to the very tool looking for
// it. A parser that silently drops what it does not expect will hide the next
// thing too.
//
// Skips when the corpus is absent (sibling working copy, not in git).
@Suite("PHY lanes — customer probe sweep")
struct PhyCorpusSweepTests {

    // PhyReader.parse takes the port number the walk read from the PHY's parent
    // node, which probe 01 does not record. It is passed through untouched, so
    // a placeholder is honest here: this sweep covers the lane and DisplayPort
    // logic, not the port-number join.
    private static let placeholderPortNumber = 0

    private struct MachinePhys {
        let name: String
        let blocks: [[String: Any]]
        let parsed: [RawPhyData]
    }

    private static func sweep() -> [MachinePhys] {
        ProbeCorpus.machines.compactMap { machine -> MachinePhys? in
            guard let output = machine.probe("01_walk_pd_tree.json") else { return nil }
            let blocks = ProbeCorpus.phyBlocks(in: output)
            guard !blocks.isEmpty else { return nil }
            return MachinePhys(
                name: machine.name,
                blocks: blocks,
                parsed: blocks.map { PhyReader.parse(properties: $0, portNumber: placeholderPortNumber) }
            )
        }
    }

    // Reads a lane's field straight out of the recorded dictionary, without
    // going through the reader.
    //
    // Independent of PhyReader.parse, which is what catches a lane swap, but
    // NOT independent of the loader: both sides of the comparison come from
    // ProbeCorpus, so a defect there loses the field on both sides at once and
    // this stays green. Review proved that by blanking a key in the loader.
    // ProbeCorpusTests closes it, by measuring the loader against text
    // transcribed by hand.
    private static func laneField(_ block: [String: Any], lane: String, key: String) -> String {
        let lanes = block["AppleTypeCPhyLane"] as? [String: Any] ?? [:]
        let laneDict = lanes[lane] as? [String: Any] ?? [:]
        return laneDict[key] as? String ?? ""
    }

    @Test("Each lane's transport lands in its own field", .enabled(if: ProbeCorpus.isAvailable))
    func eachLaneLandsInItsOwnField() throws {
        let machines = Self.sweep()
        try #require(machines.count > 100, "Expected machines with PHY blocks, got \(machines.count)")

        var checked = 0
        var populated = 0
        var wrong: [String] = []

        for machine in machines {
            for (block, phy) in zip(machine.blocks, machine.parsed) {
                checked += 1

                let lane0 = Self.laneField(block, lane: "Lane 0", key: "Transport")
                let lane1 = Self.laneField(block, lane: "Lane 1", key: "Transport")
                if !lane0.isEmpty || !lane1.isEmpty { populated += 1 }

                if phy.lane0Transport != lane0 || phy.lane1Transport != lane1 {
                    wrong.append("\(machine.name) phy\(phy.phyID): lanes \(phy.lane0Transport)/\(phy.lane1Transport) vs recorded \(lane0)/\(lane1)")
                }
                if phy.lane0Client != Self.laneField(block, lane: "Lane 0", key: "Client") {
                    wrong.append("\(machine.name) phy\(phy.phyID): lane 0 client")
                }
                if phy.lane1Client != Self.laneField(block, lane: "Lane 1", key: "Client") {
                    wrong.append("\(machine.name) phy\(phy.phyID): lane 1 client")
                }
            }
        }

        try #require(checked > 300, "Expected hundreds of PHYs, got \(checked)")
        // A machine with both lanes idle would compare "" to "" and prove
        // nothing, so require a real population of live lanes.
        try #require(populated > 50, "Expected PHYs with a live lane, got \(populated)")
        #expect(wrong.isEmpty, "\(wrong.count) mismatches: \(wrong.prefix(5))")
    }

    @Test("Transports come from the vocabulary the UI knows", .enabled(if: ProbeCorpus.isAvailable))
    func transportsComeFromAKnownVocabulary() throws {
        var seen: Set<String> = []
        for machine in Self.sweep() {
            for phy in machine.parsed {
                if !phy.lane0Transport.isEmpty { seen.insert(phy.lane0Transport) }
                if !phy.lane1Transport.isEmpty { seen.insert(phy.lane1Transport) }
                if !phy.usb2Transport.isEmpty { seen.insert(phy.usb2Transport) }
            }
        }

        // The lane bars in the UI switch on these strings. A new one appearing
        // on future silicon should be a test failure here rather than a lane
        // that silently renders as idle.
        let known: Set<String> = ["CIO", "DisplayPort", "USB3", "USB2"]
        #expect(seen.isSubset(of: known), "Unknown transports: \(seen.subtracting(known).sorted())")
        #expect(seen.contains("CIO") && seen.contains("DisplayPort"), "Expected real transports, saw \(seen.sorted())")
    }

    @Test("hasActiveTransport follows the lanes", .enabled(if: ProbeCorpus.isAvailable))
    func hasActiveTransportFollowsTheLanes() throws {
        var active = 0
        var idle = 0

        for machine in Self.sweep() {
            for phy in machine.parsed {
                let expected = !phy.lane0Transport.isEmpty || !phy.lane1Transport.isEmpty
                #expect(phy.hasActiveTransport == expected, "\(machine.name) phy\(phy.phyID)")
                if expected { active += 1 } else { idle += 1 }
            }
        }

        // Both cases must occur or the rule is only tested one way.
        #expect(active > 50, "Expected active PHYs, got \(active)")
        #expect(idle > 50, "Expected idle PHYs, got \(idle)")
    }

    @Test("A DisplayPort link rate is found wherever one was recorded", .enabled(if: ProbeCorpus.isAvailable))
    func displayPortLinkRateIsFoundWhereverRecorded() throws {
        // The reader hunts for "PCLK 0", "PCLK 1"... and takes the first with a
        // Link Rate, which is only exercised by a machine that actually has a
        // display attached.
        var recorded = 0
        var found = 0
        var missed: [String] = []

        for machine in Self.sweep() {
            for (block, phy) in zip(machine.blocks, machine.parsed) {
                let pclk = block["AppleTypeCPhyDisplayPortPclk"] as? [String: Any] ?? [:]
                let anyRate = pclk.values
                    .compactMap { ($0 as? [String: Any])?["Link Rate"] as? String }
                    .first { !$0.isEmpty }

                guard let anyRate else { continue }
                recorded += 1
                if phy.dpLinkRate.isEmpty {
                    missed.append("\(machine.name) phy\(phy.phyID): recorded \(anyRate), read nothing")
                } else {
                    found += 1
                }
            }
        }

        try #require(recorded > 10, "Expected machines driving a display, got \(recorded)")
        #expect(missed.isEmpty, "\(missed.count) link rates not found: \(missed.prefix(5))")
        #expect(found == recorded)
    }

    // Mirrors the PCLK sweep above, but for DisplayPort tunnelled over CIO,
    // which the reader hunts for under "Tunnel 0", "Tunnel 1"... in a
    // separate dictionary from native alt-mode's PCLK data.
    @Test("A DP tunnel link rate is found wherever one was recorded", .enabled(if: ProbeCorpus.isAvailable))
    func dpTunnelLinkRateIsFoundWhereverRecorded() throws {
        var recorded = 0
        var found = 0
        var missed: [String] = []

        for machine in Self.sweep() {
            for (block, phy) in zip(machine.blocks, machine.parsed) {
                let tunnel = block["AppleTypeCPhyDisplayPortTunnel"] as? [String: Any] ?? [:]
                let anyRate = tunnel.values
                    .compactMap { ($0 as? [String: Any])?["Link Rate"] as? String }
                    .first { !$0.isEmpty }

                guard let anyRate else { continue }
                recorded += 1
                if phy.dpTunnel.isEmpty {
                    missed.append("\(machine.name) phy\(phy.phyID): recorded \(anyRate), read nothing")
                } else {
                    found += 1
                }
            }
        }

        try #require(recorded > 10, "Expected machines with a tunnelled DP link, got \(recorded)")
        #expect(missed.isEmpty, "\(missed.count) tunnel link rates not found: \(missed.prefix(5))")
        #expect(found == recorded)
    }
}
