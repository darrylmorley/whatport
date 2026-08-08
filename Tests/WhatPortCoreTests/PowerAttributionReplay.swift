import Foundation
import Testing
@testable import WhatPortCore
@testable import WhatPortIOKit

// Replays the probe corpus through the REAL power-attribution path:
// PortManager.applySnapshot -> correlate -> applyChargerPower,
// SMCContractAttribution.resolve, the MagSafe-vs-USB-C decision, and
// applySMCPower. Every other sweep in this repo replays one reader; this one
// assembles a whole PortManagerSnapshot per machine (hpmPorts, ccData,
// chargerData, chargingPower, chargerIdentity, smcPortPower,
// smcPortContracts) from five probes and hands it to production code exactly
// the way SnapshotAdapter does, so the decisions that used to be exercised
// only by hand-built fixtures (MagSafePowerTests) now also run against ~700
// real machines.
//
// phy/tb/device/display/stats/transports/pdReliability stay empty: nothing
// in the power path reads them. powerData (PowerOutDetails) also stays
// empty; see the coverage-map note this PR adds for why.
//
// Skips (never fails) when the corpus is absent, matching every other sweep.
@Suite("Power attribution: customer probe replay")
struct PowerAttributionReplayTests {

    struct Replayed: Sendable {
        let name: String
        let chip: String
        let snapshot: PortManagerSnapshot
        let manager: PortManager
    }

    // Reasons a machine did not make it into the replay, counted rather than
    // silently dropped (see corpus-test-coverage.md's "machine lists built
    // with compactMap" lesson: a sweep that only ever counts successes cannot
    // tell "the corpus is small" apart from "the loader broke").
    enum SkipReason: String, Sendable, Error {
        case missingHPMRoster   // no probe 01/35, or nothing parsed to a real port
        case missingCCData      // no CC blocks on probe 01
        case missingProbe17
        case truncatedProbe17   // hit the 64KB pipe cap
        case missingProbe32
        case truncatedProbe32   // hit the 64KB pipe cap, or the section isolator rejected it
        case missingProbe34     // absent, or no SMC keys parsed
    }

    // Builds one machine's PortManagerSnapshot from its recorded probes, or
    // reports why it could not be built.
    //
    // Every raw->input conversion here mirrors SnapshotAdapter.convert
    // field-for-field; SnapshotAdapter is the authoritative reference for how
    // production wires a Raw* struct into the matching *Input, and this does
    // not invent a different mapping.
    static func snapshot(for machine: ProbeCorpus.Machine) -> Result<PortManagerSnapshot, SkipReason> {
        // --- hpmPorts: probe 01 IOAccessoryManager blocks + probe 35 roster,
        // through the real HPMReader.parse / HPMReader.roster (same pattern
        // HPMRosterCorpusSweepTests uses). ---
        guard let walk = machine.probe("01_walk_pd_tree.json") else { return .failure(.missingHPMRoster) }
        let accessoryBlocks = ProbeCorpus.accessoryBlocks(in: walk)
        guard !accessoryBlocks.isEmpty else { return .failure(.missingHPMRoster) }

        guard let rosterOutput = machine.probe("35_hpm_port_uuid.json") else { return .failure(.missingHPMRoster) }
        let rosterEntries = ProbeCorpus.roster(in: rosterOutput)
        guard !rosterEntries.isEmpty else { return .failure(.missingHPMRoster) }
        let uuidsByPort = Dictionary(
            rosterEntries.map { ("\($0.portType):\($0.portNumber)", $0.uuid) },
            uniquingKeysWith: { first, _ in first }
        )

        let rawHPMPorts = accessoryBlocks.compactMap { block -> RawHPMPort? in
            let portType = block.properties["PortTypeDescription"] as? String ?? ""
            let key = "\(portType):\(block.portNumber ?? -1)"
            return HPMReader.parse(
                properties: block.properties,
                entryName: block.entryName,
                portNumber: block.portNumber,
                controllerUUID: uuidsByPort[key]
            )
        }
        let hpmPorts = HPMReader.roster(from: rawHPMPorts).map { hpm in
            HPMPortInput(
                uuid: hpm.uuid,
                portNumber: hpm.portNumber,
                portType: hpm.portType,
                overcurrentCount: hpm.overcurrentCount,
                plugEventCount: hpm.plugEventCount,
                connectionCount: hpm.connectionCount,
                authorizationStatus: hpm.authorizationStatus,
                ldcmStatus: hpm.ldcmStatus,
                provisionedTransports: hpm.provisionedTransports,
                unauthorizedTransports: hpm.unauthorizedTransports,
                liquidDetected: hpm.liquidDetected,
                mitigationsActive: hpm.mitigationsActive
            )
        }
        guard !hpmPorts.isEmpty else { return .failure(.missingHPMRoster) }

        // --- ccData: probe 01 IOPortTransportStateCC blocks, joined to the
        // sibling SOP' blocks for cable identity, through CCReader.parse. ---
        let ccBlocks = ProbeCorpus.ccBlocks(in: walk)
        guard !ccBlocks.isEmpty else { return .failure(.missingCCData) }

        let sopBlocks = ProbeCorpus.sopPrimeBlocks(in: walk)
        let cableByKey = Dictionary(
            sopBlocks.compactMap { block -> (String, (productType: String, pdRevision: Int))? in
                guard let identity = CCReader.cableIdentity(fromSOPProperties: block) else { return nil }
                let portNumber = ioInt(block["ParentBuiltInPortNumber"])
                let portType = ioString(block["ParentPortTypeDescription"])
                guard portNumber > 0 else { return nil }
                return ("\(portType):\(portNumber)", identity)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let rawCCData: [RawCCData] = ccBlocks.compactMap { block in
            let portNumber = ioInt(block["ParentBuiltInPortNumber"])
            let portType = ioString(block["ParentPortTypeDescription"])
            let cable = cableByKey["\(portType):\(portNumber)"]
            return CCReader.parse(
                properties: block,
                cableProductType: cable?.productType ?? "",
                cablePDRevision: cable?.pdRevision ?? 0
            )
        }
        // Same dedup/ordering CCReader.readAll applies to a live registry
        // walk (at most one entry per (portNumber, portType), sorted by port
        // number), so the replay can never construct a snapshot production's
        // walk could not have produced.
        let ccData: [CCInput] = CCReader.dedupedAndSorted(rawCCData).map { raw in
            CCInput(
                portNumber: raw.portNumber,
                portType: raw.portType,
                active: raw.active,
                cableProductType: raw.cableProductType,
                cablePDRevision: raw.cablePDRevision
            )
        }
        guard !ccData.isEmpty else { return .failure(.missingCCData) }

        // --- chargerData: probe 17 IOPortFeaturePowerSource blocks, through
        // ChargerReader.parse. An empty result (no PD source published at
        // all right now) is a legitimate reading, not a skip. ---
        guard let probe17 = machine.probe("17_deep_property_dump.json") else { return .failure(.missingProbe17) }
        guard !ProbeCorpus.isPipeTruncated(probe17) else { return .failure(.truncatedProbe17) }
        let chargerData: [ChargerInput] = ProbeCorpus.chargerBlocks(inFullOutput: probe17).compactMap { block in
            ChargerReader.parse(properties: block)?.toChargerInput()
        }

        // --- chargingPower / chargerIdentity: probe 32, through
        // PowerReader's parse seams. nil results (no charger connected right
        // now) are legitimate readings, not a skip. ---
        guard let probe32 = machine.probe("32_smart_battery_full_keys.json") else { return .failure(.missingProbe32) }
        guard ProbeCorpus.isolatedSmartBatterySection(inFullOutput: probe32) != nil else { return .failure(.truncatedProbe32) }
        let batteryProperties = ProbeCorpus.smartBatteryProperties(inFullOutput: probe32)
        let rawChargingPower = PowerReader.parseChargingPower(properties: batteryProperties)
        let rawChargerIdentity = PowerReader.parseChargerIdentity(properties: batteryProperties)

        // Raw -> Input, mirroring SnapshotAdapter.convert field-for-field.
        let chargingPower = rawChargingPower.map { cp in
            ChargingPowerInput(
                systemPowerIn: cp.systemPowerIn,
                systemVoltageIn: cp.systemVoltageIn,
                systemCurrentIn: cp.systemCurrentIn,
                isCharging: cp.isCharging,
                fullyCharged: cp.fullyCharged,
                notChargingReason: cp.notChargingReason
            )
        }
        let chargerIdentity = rawChargerIdentity.map { ci in
            ChargerIdentityInput(
                name: ci.name,
                manufacturer: ci.manufacturer,
                description: ci.description,
                maxWatts: ci.maxWatts,
                pdos: ci.pdos.map { ChargerPDO(voltageMV: $0.voltageMV, currentMA: $0.currentMA) }
            )
        }

        // --- smcPortPower / smcPortContracts: probe 34, through
        // SMCPowerReader's real builders (same pattern
        // SMCPowerCorpusSweepTests uses). ---
        guard let probe34 = machine.probe("34_smc_power_keys.json") else { return .failure(.missingProbe34) }
        let smcKeys = ProbeCorpus.smcKeys(in: probe34)
        guard !smcKeys.isEmpty else { return .failure(.missingProbe34) }

        let smcPortPower = SMCPowerReader.buildPortPowerChannels(readKey: { smcKeys[$0] }).map {
            SMCPortPowerInput(present: $0.present, volts: $0.volts, amps: $0.amps, uuid: $0.uuid, channel: $0.channel)
        }
        let smcPortContracts = SMCPowerReader.buildPortContracts(readKey: { smcKeys[$0] }).map {
            SMCPortContractInput(
                channel: $0.channel,
                uuid: $0.uuid,
                powerMW: $0.powerMW,
                voltageMV: $0.voltageMV,
                currentMA: $0.currentMA,
                label: $0.label
            )
        }

        return .success(PortManagerSnapshot(
            hpmPorts: hpmPorts,
            ccData: ccData,
            chargerData: chargerData,
            chargingPower: chargingPower,
            chargerIdentity: chargerIdentity,
            smcPortPower: smcPortPower,
            smcPortContracts: smcPortContracts
        ))
    }

    // Runs every machine's snapshot through the real PortManager.applySnapshot
    // (which calls the private correlate() internally, same as production),
    // and tallies why any others were skipped. Memoized: every sweep test
    // below reads the same replay rather than re-parsing ~700 machines
    // across five probes each.
    static func replay() -> (replayed: [Replayed], skipped: [SkipReason: Int]) {
        var replayed: [Replayed] = []
        var skipped: [SkipReason: Int] = [:]

        for machine in ProbeCorpus.machines {
            switch snapshot(for: machine) {
            case .success(let snap):
                let manager = PortManager()
                manager.applySnapshot(snap)
                replayed.append(Replayed(
                    name: machine.name,
                    chip: machine.chip("01_walk_pd_tree.json"),
                    snapshot: snap,
                    manager: manager
                ))
            case .failure(let reason):
                skipped[reason, default: 0] += 1
            }
        }

        return (replayed, skipped)
    }

    static let replayResult = replay()

    // MARK: - 1. Global invariants

    // Mutations used to prove this can fail:
    // 1. Inverted `if !port.ccConnected` to `if port.ccConnected`, which
    //    flags virtually every incoming port (they are almost always
    //    CC-connected, correctly). Went red with ~300 flagged machines.
    // 2. Tightened the watts bound from `watts >= 0` to `watts > 0` while
    //    developing this sweep (see the comment on that check): production
    //    genuinely attributes 0 W on 12 real machines (a winning USB-C
    //    contract with a momentarily idle telemetry sample), so the
    //    stricter bound went red against real data before the bound itself
    //    was corrected.
    // Both reverted/corrected.
    //
    // Not yet observed to go red: `incoming.count > 1` relaxed to `> 2`.
    // No machine in this corpus currently has two ports incoming at once
    // (matches MagSafePowerTests' own comment: "never observed in 532
    // corpus machines"), so that half of the invariant is currently proven
    // by construction (SMCContractAttribution's gates) and by the DAR-226
    // sweep below, not by a red run of this specific line.
    @Test(
        "At most one port shows incoming power, always CC-connected, plausible watts, never both MagSafe and USB-C",
        .enabled(if: ProbeCorpus.isAvailable)
    )
    func globalInvariantsHoldAcrossEveryReplayedMachine() throws {
        let (replayed, _) = Self.replayResult
        try #require(replayed.count > 200, "Expected hundreds of replayed machines, got \(replayed.count)")

        var violations: [String] = []
        // Counted so this test cannot pass vacuously: if attribution ever
        // produced zero incoming ports across the whole corpus (e.g. a
        // regression that stops applyChargerPower/applySMCPower from ever
        // attaching PortPower), every loop below would simply have nothing
        // to check and the invariants would hold by having nothing to say.
        var machinesWithIncomingPort = 0
        for r in replayed {
            let incoming = r.manager.ports.filter { $0.power?.direction == .incoming }
            if !incoming.isEmpty { machinesWithIncomingPort += 1 }

            if incoming.count > 1 {
                violations.append("\(r.name): \(incoming.count) ports incoming at once")
            }
            for port in incoming {
                if !port.ccConnected {
                    violations.append("\(r.name): port \(port.id) incoming without ccConnected")
                }
                // Lower bound is 0, not exclusive: applyChargerPower attaches
                // a USB-C port's PortPower whenever a winning contract node
                // exists and the port is CC-connected, with no gate on
                // systemPowerIn itself (unlike the MagSafe path, which does
                // gate on it -- see buildNonUSBCPorts). 12 real corpus
                // machines are plugged in, fully charged, holding a genuine
                // contract, and drew exactly 0 mW at the instant PowerTelemetryData
                // was sampled: a real charger contract with a momentarily
                // idle draw, not an implausible reading.
                if let watts = port.power?.watts, !(watts >= 0 && watts < 400) {
                    violations.append("\(r.name): port \(port.id) implausible watts \(watts)")
                }
            }
            if incoming.contains(where: { $0.portType == .magSafe }),
               incoming.contains(where: { $0.portType == .usbC }) {
                violations.append("\(r.name): both MagSafe and USB-C incoming at once")
            }
        }

        #expect(violations.isEmpty, "\(violations.count) invariant violations: \(violations.prefix(5))")

        // Observed on the 2026-08-08 corpus: 361 of 593 replayed machines
        // attribute at least one incoming port. Floor set well below that
        // (corpus growth should not make this brittle) and well above zero
        // (so a regression that stops applyChargerPower/applySMCPower from
        // ever attaching PortPower is caught, rather than the loop above
        // simply having nothing to check and the invariants passing
        // vacuously).
        try #require(
            machinesWithIncomingPort >= 150,
            "Expected a floor of machines attributing at least one incoming port, got \(machinesWithIncomingPort)"
        )
    }

    // MARK: - 2. DAR-223: the M1 Pro/Max/Ultra SMC fallback

    // The fallback (applySMCContract) is the only path that can put an
    // incoming reading on a USB-C port when chargerData has no winning USB-C
    // node contract: applyChargerPower requires maxWatts > 0, and in this
    // corpus a USB-C node only ever carries maxWatts > 0 together with a
    // winning contract (PowerSourceOptions is always the opaque `<CFType 17>`
    // placeholder here, so the highest-PDO fallback ChargerReader itself has
    // never has anything to fall back to). applySMCPower never sets
    // `.incoming` at all (see its `direction: .outgoing` literal). So under
    // the gate below, a USB-C incoming port is evidence the SMC path fired.
    //
    // Mutation used to prove this can fail: inverted `if usbCIncomingEstimated`
    // to `if !usbCIncomingEstimated` in the "despite a winning node" check,
    // which flags a machine as a violation whenever its USB-C contract was
    // NOT estimated (i.e. every ordinary, correctly-behaving machine with a
    // winning node). Went red with ~199 flagged machines, confirming
    // `fallbackFiredDespiteWinningNode.isEmpty` is actually load-bearing.
    // Reverted.
    @Test(
        "The SMC-contract fallback only attributes USB-C power where probe 17 has no winning USB-C contract",
        .enabled(if: ProbeCorpus.isAvailable)
    )
    func smcFallbackFiresOnlyWhereMacOSPublishedNoUSBCNode() throws {
        let (replayed, _) = Self.replayResult

        var eligible = 0
        var fallbackFired = 0
        var machinesWithWinningNode = 0
        var fallbackFiredDespiteWinningNode: [String] = []

        for r in replayed {
            let hasWinningUSBCNode = r.snapshot.chargerData.contains { $0.portType == "USB-C" && $0.hasWinningContract }
            let usbCIncomingEstimated = r.manager.ports.contains {
                $0.portType == .usbC && $0.power?.direction == .incoming && ($0.power?.contractIsEstimated ?? false)
            }

            if hasWinningUSBCNode {
                machinesWithWinningNode += 1
                if usbCIncomingEstimated {
                    fallbackFiredDespiteWinningNode.append(r.name)
                }
            }

            let externallyPowered = r.snapshot.chargingPower != nil
            guard externallyPowered, !hasWinningUSBCNode else { continue }
            eligible += 1
            if usbCIncomingEstimated { fallbackFired += 1 }
        }

        try #require(machinesWithWinningNode > 100, "Expected machines with a winning USB-C node, got \(machinesWithWinningNode)")
        #expect(
            fallbackFiredDespiteWinningNode.isEmpty,
            "Fallback fired despite a winning node: \(fallbackFiredDespiteWinningNode.prefix(5))"
        )

        // Observed on the 2026-08-08 corpus: 271 machines eligible (externally
        // powered, no winning USB-C node), 67 of those had the fallback fire.
        // Floor set well below that so the corpus growing does not make this
        // brittle. smc-charging-contract.md's own count (41 of 784, replayed
        // directly against IOKit/SMC decoders rather than through the domain
        // layer) is not expected to match exactly: this sweep's denominator
        // is machines with a full 5-probe snapshot, which is a stricter and
        // differently-shaped set than that document's.
        #expect(fallbackFired >= 30, "Expected the M1 Pro/Max/Ultra fallback to fire on a floor of machines, got \(fallbackFired) of \(eligible) eligible")

        // Independent re-derivation (DAR-227): bypasses SMCPowerReader,
        // PortManager and SMCContractAttribution entirely. Re-decodes the
        // raw SMC bytes with a standalone big-endian reducer written fresh
        // in this file, and re-derives "no winning USB-C node" and
        // "externally connected" with regex over the raw probe text instead
        // of ProbeCorpus's line-by-line block parser. See
        // IndependentSMCFallbackCheck below.
        let independent = IndependentSMCFallbackCheck.count()
        #expect(
            fallbackFired <= independent.upperBound,
            "Production fired on \(fallbackFired) machines, more than the independent upper bound of \(independent.upperBound)"
        )
        try #require(independent.upperBound >= fallbackFired, "Independent check should never be stricter than production")
    }

    // MARK: - 3. DAR-226: MagSafe vs USB-C

    // Mutation used to prove this can fail: inverted the second check's
    // condition (`if ... contains(...)` to `if !... contains(...)`), which
    // flags a machine as a violation whenever MagSafe does NOT also claim
    // incoming while USB-C holds the node contract (i.e. every ordinary,
    // correctly-behaving machine). Went red with ~199 flagged machines.
    // Reverted.
    @Test(
        "MagSafe and USB-C never both claim incoming power, and a USB-C node contract blanks MagSafe",
        .enabled(if: ProbeCorpus.isAvailable)
    )
    func magSafeAndUSBCNeverBothClaimIncoming() throws {
        let (replayed, _) = Self.replayResult

        var magSafeDeliveringMachines = 0
        var violations: [String] = []
        var usbCNodeMachines = 0

        for r in replayed {
            let magSafeIncoming = r.manager.ports.contains { $0.portType == .magSafe && $0.power?.direction == .incoming }
            if magSafeIncoming {
                magSafeDeliveringMachines += 1
                if r.manager.ports.contains(where: { $0.portType == .usbC && $0.power?.direction == .incoming }) {
                    violations.append("\(r.name): MagSafe delivering but a USB-C port also claims incoming")
                }
            }

            let usbCNodeContract = r.snapshot.chargerData.contains { $0.portType == "USB-C" && $0.hasWinningContract }
            if usbCNodeContract {
                usbCNodeMachines += 1
                if r.manager.ports.contains(where: { $0.portType == .magSafe && $0.power?.direction == .incoming }) {
                    violations.append("\(r.name): USB-C holds the node contract but MagSafe also claims incoming")
                }
            }
        }

        // Observed on the 2026-08-08 corpus: 99 machines with MagSafe
        // delivering, 199 with a winning USB-C node contract.
        try #require(magSafeDeliveringMachines > 50, "Expected machines with MagSafe delivering, got \(magSafeDeliveringMachines)")
        try #require(usbCNodeMachines > 100, "Expected machines with a USB-C node contract, got \(usbCNodeMachines)")
        #expect(violations.isEmpty, "\(violations.count) violations: \(violations.prefix(5))")

        // Independent re-derivation (DAR-248 review fix): a raw-text scan
        // over probe 17 for a WinningPowerSourceOption dict carrying a
        // parsed positive Max Power, restricted to the same five-probe
        // eligibility gate the replay itself requires (see
        // IndependentUSBCWinningNodeCheck's comment). Calls none of
        // ProbeCorpus's block parsers and none of ChargerReader.parse, so a
        // bug shared between the two could not hide behind their agreement.
        // Matched exactly (199 == 199) on the 2026-08-08 corpus; a small
        // tolerance is kept rather than exact equality so the check does not
        // become brittle to corpus growth or an unrelated formatting change
        // in a handful of captures.
        let independentUSBCNodeCount = IndependentUSBCWinningNodeCheck.count()
        #expect(
            abs(independentUSBCNodeCount - usbCNodeMachines) <= 5,
            "Independent USB-C-node count \(independentUSBCNodeCount) disagrees with the replay's \(usbCNodeMachines) by more than the tolerance"
        )
    }

    // MARK: - 4. DAR-247: the 5 V floor, and never from an outgoing channel

    // Mutation used to prove this can fail, two halves:
    // 1. Loosened the "sourcing power out" threshold below from `> 0.5` to
    //    `> -1`, which flags every incoming port whose UUID matches any SMC
    //    power-out channel at all, including idle ones reading a legitimate
    //    near-zero watts. Went red.
    // 2. Raised the 4750-5250 mV floor from 5 to 50, past the observed count
    //    of 11. Went red ("11 >= 50" failed).
    // Both reverted.
    @Test(
        "4750-5250 mV SMC contracts still attribute, and never from a channel sourcing power out",
        .enabled(if: ProbeCorpus.isAvailable)
    )
    func fiveVoltFloorAttributesAndNeverFromAnOutgoingChannel() throws {
        let (replayed, _) = Self.replayResult

        var fiveVoltFloorMachines: [String] = []
        var violations: [String] = []

        for r in replayed {
            // 4750-5250 mV: the tolerance band around USB-PD's 5 V rail that
            // SMCContractAttribution's minimumContractVoltageMV (4500) and
            // SMCPowerCorpusSweepTests' own plausibility floor both clear.
            let floorContracts = r.snapshot.smcPortContracts.filter {
                $0.voltageMV >= 4750 && $0.voltageMV < 5250 && $0.currentMA > 0
            }
            for contract in floorContracts {
                guard let port = r.manager.ports.first(where: {
                    $0.uuid.map(SMCContractAttribution.normalisedUUID) == contract.uuid
                }) else { continue }
                if port.power?.direction == .incoming {
                    fiveVoltFloorMachines.append(r.name)
                    break
                }
            }

            for port in r.manager.ports where port.power?.direction == .incoming {
                guard let uuid = port.uuid else { continue }
                let normalised = SMCContractAttribution.normalisedUUID(uuid)
                if let channel = r.snapshot.smcPortPower.first(where: { $0.uuid == normalised }), channel.watts > 0.5 {
                    violations.append("\(r.name): port \(port.id) incoming while its SMC channel sources \(channel.watts) W out")
                }
            }
        }

        // Observed on the 2026-08-08 corpus: 11 machines. The historical
        // figure (research/smc-charging-contract.md) is six machines across
        // the whole 365-machine SMC-contract corpus; this replay's
        // denominator (a full 5-probe snapshot, and a slightly wider 4750-5250
        // mV band rather than an exact 4750 mV pin) differs, so the floor
        // here is set well below 11 rather than matched to either figure.
        #expect(fiveVoltFloorMachines.count >= 5, "Expected a floor of 4750-5250 mV machines to still attribute, got \(fiveVoltFloorMachines.count)")
        #expect(violations.isEmpty, "\(violations.count) attributions from an outgoing channel: \(violations.prefix(5))")
    }

    // MARK: - 5. Replay coverage floor

    // Mutation used to prove this can fail: raised the floor past the
    // observed count (see comment on the assertion). Went red, reverted.
    @Test("A floor of the corpus replays through a full 5-probe snapshot", .enabled(if: ProbeCorpus.isAvailable))
    func replayCoverageMeetsAFloor() throws {
        let (replayed, skipped) = Self.replayResult

        // Observed on the 2026-08-08 corpus (1176 machine directories): 593
        // machines replayed. The rest were skipped, mostly for
        // missingHPMRoster (473: Intel Macs among them, which publish no HPM
        // controller layer at all, so this power path is not written for
        // them) and truncatedProbe32 (84, the 64KB pipe cap). Floor set well
        // below the observed count so the corpus growing does not make this
        // test brittle, and well above zero so a loader regression that
        // empties the replay is caught.
        try #require(replayed.count >= 400, "Expected a floor of replayed machines, got \(replayed.count)")

        // Independent re-derivation (DAR-227): regex/substring presence
        // checks over the raw probe text, calling none of ProbeCorpus's
        // block parsers and none of the *Reader.parse functions. See
        // IndependentReplayEligibilityCheck below.
        let independentCount = IndependentReplayEligibilityCheck.count()
        let diff = abs(independentCount - replayed.count)
        #expect(
            diff <= max(20, replayed.count / 10),
            "Independent eligibility count \(independentCount) disagrees with the replay's \(replayed.count) by more than 10%"
        )

        #expect(skipped.values.reduce(0, +) > 0, "Expected some machines to be skipped (e.g. Intel), got none")
    }
}
