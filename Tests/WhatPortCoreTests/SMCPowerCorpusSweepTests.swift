import Foundation
import Testing
@testable import WhatPortIOKit

// Replays recorded SMC key dumps through the real channel and contract
// builders. The SMC path decides which port a charger is attributed to on
// M1 Pro / Max / Ultra, where macOS publishes no power-source node at all, and
// its endianness is the kind of mistake that fails silently: a little-endian
// read of a 20000 mV contract still looks like a plausible voltage.
//
// Skips when the corpus is absent (it lives in the sibling whatcable-app
// working copy and is not in git).
@Suite("SMC power — customer probe sweep")
struct SMCPowerCorpusSweepTests {

    private struct MachineKeys {
        let name: String
        let chip: String
        let keys: [String: [UInt8]]
        let roster: [ProbeCorpus.RosterPort]
    }

    private static func machinesWithKeys() -> [MachineKeys] {
        ProbeCorpus.machines.compactMap { machine in
            guard let output = machine.probe("34_smc_power_keys.json") else { return nil }
            let keys = ProbeCorpus.smcKeys(in: output)
            guard !keys.isEmpty else { return nil }
            let roster = machine.probe("35_hpm_port_uuid.json").map { ProbeCorpus.roster(in: $0) } ?? []
            return MachineKeys(
                name: machine.name,
                chip: machine.chip("34_smc_power_keys.json"),
                keys: keys,
                roster: roster
            )
        }
    }

    // Dashes stripped, lowercased: the form the SMC publishes DxUI in, and what
    // PortManager normalises the HPM UUID to before joining.
    private static func normalised(_ uuid: String) -> String {
        uuid.replacingOccurrences(of: "-", with: "").lowercased()
    }

    @Test("Every channel with a controller UUID resolves to exactly one port", .enabled(if: ProbeCorpus.isAvailable))
    func everyChannelResolvesToExactlyOnePort() throws {
        let machines = Self.machinesWithKeys().filter { !$0.roster.isEmpty }
        try #require(machines.count > 200, "Expected hundreds of machines, got \(machines.count)")

        var channels = 0
        var resolved = 0
        var failures: [String] = []

        for machine in machines {
            let rosterUUIDs = machine.roster.map { Self.normalised($0.uuid) }

            for channel in SMCPowerReader.buildPortPowerChannels(readKey: { machine.keys[$0] }) {
                channels += 1
                let matches = rosterUUIDs.filter { $0 == channel.uuid }.count
                if matches == 1 {
                    resolved += 1
                } else {
                    failures.append("\(machine.name) D\(channel.channel): \(matches) matching ports")
                }
            }
        }

        // The join is the whole basis for attributing SMC power to a port: the
        // D-index is not the port number (D3 is USB-C@4 on this Mac), so a
        // channel that resolves to zero or two ports has nowhere safe to go.
        try #require(channels > 500, "Expected hundreds of channels, got \(channels)")
        #expect(failures.isEmpty, "\(failures.count) of \(channels) channels failed to resolve: \(failures.prefix(5))")
        #expect(resolved == channels)
    }

    @Test("Contract integers decode big-endian and multiply out", .enabled(if: ProbeCorpus.isAvailable))
    func contractIntegersDecodeBigEndian() throws {
        let machines = Self.machinesWithKeys()

        var contracts = 0
        var implausible: [String] = []
        var productMismatch: [String] = []

        for machine in machines {
            for contract in SMCPowerReader.buildPortContracts(readKey: { machine.keys[$0] }) {
                contracts += 1

                // USB-PD's lowest rail is 5 V and the highest contract anyone
                // negotiates today is well under 60 V. The floor is 4500 rather
                // than 5000 because six machines in the corpus report a 5 V
                // contract as 4750 mV, which is inside USB-PD's 5% tolerance and
                // decodes exactly (4750 x 3000 = 14250 mW). Worth knowing: the
                // shipped gate in SMCContractAttribution is the stricter 5000
                // and would reject all six.
                if contract.voltageMV < 4500 || contract.voltageMV > 60_000 {
                    implausible.append("\(machine.name) D\(contract.channel): \(contract.voltageMV) mV")
                }

                // The three keys are independent SMC reads, so agreement
                // between them is evidence the decode is right rather than
                // self-consistent nonsense. Tolerance covers the SMC rounding
                // each figure separately.
                let product = Double(contract.voltageMV) * Double(contract.currentMA) / 1000.0
                let stated = Double(contract.powerMW)
                if stated > 0, abs(product - stated) / stated > 0.02 {
                    productMismatch.append("\(machine.name) D\(contract.channel): \(contract.voltageMV)mV x \(contract.currentMA)mA vs \(contract.powerMW)mW")
                }
            }
        }

        try #require(contracts > 100, "Expected hundreds of contracts, got \(contracts)")
        #expect(implausible.isEmpty, "\(implausible.count) implausible voltages: \(implausible.prefix(5))")
        #expect(productMismatch.isEmpty, "\(productMismatch.count) mismatches: \(productMismatch.prefix(5))")
    }

    @Test("Reading the contract keys the wrong way round is caught", .enabled(if: ProbeCorpus.isAvailable))
    func readingTheContractKeysTheWrongWayRoundIsCaught() throws {
        // Runs the real builder against a readKey that hands back reversed
        // bytes, which is what wiring the little-endian decoder to these keys
        // would produce, and requires the resulting figures to be visibly
        // wrong. Feeding the decoder directly would not prove this: it would
        // test the decoder in isolation while production could still be wired
        // to the wrong one.
        var machinesChecked = 0
        var contractsChecked = 0
        var survivedUndetected: [String] = []

        for machine in Self.machinesWithKeys() {
            let correct = SMCPowerReader.buildPortContracts(readKey: { machine.keys[$0] })
            guard !correct.isEmpty else { continue }
            machinesChecked += 1

            // Only the integer keys are byte-swapped: the float keys next door
            // really are little-endian, and swapping those too would be a
            // different mistake.
            let swapped = SMCPowerReader.buildPortContracts(readKey: { key in
                guard let bytes = machine.keys[key] else { return nil }
                let isInteger = key.hasSuffix("MP") || key.hasSuffix("MV") || key.hasSuffix("MI")
                return isInteger ? bytes.reversed() : bytes
            })

            for contract in swapped {
                contractsChecked += 1
                let plausibleVoltage = contract.voltageMV >= 4500 && contract.voltageMV <= 60_000
                let product = Double(contract.voltageMV) * Double(contract.currentMA) / 1000.0
                let consistent = contract.powerMW > 0
                    && abs(product - Double(contract.powerMW)) / Double(contract.powerMW) <= 0.02
                if plausibleVoltage && consistent {
                    survivedUndetected.append("\(machine.name) D\(contract.channel): \(contract.voltageMV)mV")
                }
            }
        }

        try #require(machinesChecked > 50, "Expected machines with contracts, got \(machinesChecked)")
        try #require(contractsChecked > 50, "Expected swapped contracts to inspect, got \(contractsChecked)")

        // If a byte-swapped read ever produced figures that both look like a
        // voltage AND multiply out, the checks in the test above would not
        // catch that regression on that machine.
        #expect(
            survivedUndetected.isEmpty,
            "\(survivedUndetected.count) byte-swapped contracts look legitimate: \(survivedUndetected.prefix(5))"
        )
    }

    @Test("A channel with no controller is dropped", .enabled(if: ProbeCorpus.isAvailable))
    func aChannelWithNoControllerIsDropped() throws {

        // All 1848 DxUI keys in the corpus are populated, so the all-zero case
        // (a channel with no port controller behind it) never occurs naturally
        // and the guard would go untested. Take a real machine's keys and zero
        // one channel's UUID: that channel must disappear rather than resolve
        // to a port whose UUID happens to be zero.
        var exercised = 0
        for machine in Self.machinesWithKeys().prefix(40) {
            let before = SMCPowerReader.buildPortPowerChannels(readKey: { machine.keys[$0] })
            guard let target = before.first else { continue }

            var zeroed = machine.keys
            zeroed["D\(target.channel)UI"] = [UInt8](repeating: 0, count: 16)
            let after = SMCPowerReader.buildPortPowerChannels(readKey: { zeroed[$0] })

            #expect(after.count == before.count - 1, "\(machine.name): zeroed channel should vanish")
            #expect(!after.contains { $0.channel == target.channel })
            exercised += 1
        }
        try #require(exercised > 10, "Expected to exercise the guard, did \(exercised)")
    }

    @Test("Desktops publish power out but no contract", .enabled(if: ProbeCorpus.isAvailable))
    func desktopsPublishPowerOutButNoContract() throws {

        // The contract keys are absent on every desktop in the corpus while the
        // power-out keys next door work, which is the documented reason
        // readPortContracts returns nothing there. If a future macOS starts
        // publishing them, this goes red and the comment needs revisiting.
        var desktopsWithChannels = 0
        var desktopsWithContracts: [String] = []

        for machine in Self.machinesWithKeys() {
            // No battery keys means no battery: a desktop.
            let isLaptop = machine.keys.keys.contains { $0.hasPrefix("B0") }
            guard !isLaptop else { continue }

            let channels = SMCPowerReader.buildPortPowerChannels(readKey: { machine.keys[$0] })
            let contracts = SMCPowerReader.buildPortContracts(readKey: { machine.keys[$0] })
            if !channels.isEmpty { desktopsWithChannels += 1 }
            if !contracts.isEmpty { desktopsWithContracts.append(machine.name) }
        }

        try #require(desktopsWithChannels > 10, "Expected desktops with power channels, got \(desktopsWithChannels)")
        #expect(desktopsWithContracts.isEmpty, "Desktops publishing a contract: \(desktopsWithContracts.prefix(5))")
    }
}
