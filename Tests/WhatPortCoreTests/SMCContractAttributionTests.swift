import Testing
@testable import WhatPortCore

// The M1 Pro / Max / Ultra case: macOS publishes no USB-C power-source node, so
// the charging contract has to come from the SMC. One test per gate, because a
// gate that silently stops firing is how a contract lands on the wrong port.

// MARK: - Fixtures

private let portUUID = "6230AF2D-EE59-4C1B-9F3A-1D2E3F4A5B6C"
private let portUUIDNormalised = "6230af2dee594c1b9f3a1d2e3f4a5b6c"
private let otherUUID = "11112222-3333-4444-5555-666677778888"
private let otherUUIDNormalised = "11112222333344445555666677778888"

private func contract(
    channel: Int = 2,
    uuid: String = portUUIDNormalised,
    powerMW: Int = 100_000,
    voltageMV: Int = 20_000,
    currentMA: Int = 5_000,
    label: String = ""
) -> SMCPortContractInput {
    SMCPortContractInput(
        channel: channel,
        uuid: uuid,
        powerMW: powerMW,
        voltageMV: voltageMV,
        currentMA: currentMA,
        label: label
    )
}

private func usbCPort(
    id: Int = 1,
    uuid: String? = portUUID,
    ccConnected: Bool = true,
    power: PortPower? = nil
) -> PortState {
    PortState(id: id, uuid: uuid, portType: .usbC, ccConnected: ccConnected, power: power)
}

private let incomingPower = PortPower(
    watts: 60,
    current: 3_000,
    voltage: 20_000,
    configuredVoltage: 20_000,
    configuredCurrent: 3_000,
    vconnCurrent: 0,
    direction: .incoming
)

// MARK: - The happy path

@Test func smcContractResolvesToTheUUIDMatchedPort() {
    let resolved = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort(id: 1, uuid: otherUUID), usbCPort(id: 3)],
        chargerNodes: [],
        externalConnected: true
    )

    #expect(resolved?.portID == 3)
    #expect(resolved?.contract.powerMW == 100_000)
}

// The SMC D-index is not the physical port number (verified on M5: D3 = USB-C@4,
// D4 = MagSafe@1), so a channel that matches no UUID must resolve to nothing
// rather than falling back to its index.
@Test func smcContractNeverFallsBackToTheChannelIndex() {
    let resolved = SMCContractAttribution.resolve(
        contracts: [contract(channel: 1, uuid: "deadbeef")],
        ports: [usbCPort(id: 1)],
        chargerNodes: [],
        externalConnected: true
    )

    #expect(resolved == nil)
}

// MARK: - Gates

@Test func smcContractStaysQuietWithoutExternalPower() {
    let resolved = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort()],
        chargerNodes: [],
        externalConnected: false
    )

    #expect(resolved == nil)
}

// The MagSafe half of the cross-port gate: an M1 Pro charging on MagSafe with a
// dock on USB-C must not show the dock's contract as though the Mac were
// charging from it.
@Test func smcContractStaysQuietWhenAnotherPortIsAlreadyCharging() {
    let magSafe = PortState(
        id: 101,
        uuid: otherUUID,
        portType: .magSafe,
        ccConnected: true,
        power: incomingPower
    )

    let resolved = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort(), magSafe],
        chargerNodes: [],
        externalConnected: true
    )

    #expect(resolved == nil)
}

// The other half: macOS published a winning contract somewhere, so it has
// answered and this must not talk over it.
@Test func smcContractStaysQuietWhenMacOSPublishedAWinningContract() {
    let resolved = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort()],
        chargerNodes: [
            ChargerInput(
                portType: "MagSafe 3",
                portNumber: 1,
                maxWatts: 96_000,
                voltage: 20_000,
                maxCurrent: 4_800,
                hasWinningContract: true
            )
        ],
        externalConnected: true
    )

    #expect(resolved == nil)
}

// The hole the incoming-power check alone leaves: external power is a
// system-wide fact, and a MagSafe port only gets an incoming reading while the
// battery is actively charging. Sitting at 100% on MagSafe (or paused at 80% by
// optimised charging) neither trips that check nor publishes a winning
// contract, so without this a USB-C peripheral's contract would be presented as
// the Mac's charge.
@Test func smcContractStaysQuietWhileMagSafeIsDelivering() {
    // Non-USB-C ports are attributed before this runs, so a MagSafe port that
    // is the one delivering already carries incoming power, whatever the
    // battery is doing.
    let magSafeDelivering = PortState(
        id: 101,
        uuid: otherUUID,
        portType: .magSafe,
        ccConnected: true,
        power: incomingPower
    )

    let resolved = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort(), magSafeDelivering],
        chargerNodes: [],
        externalConnected: true
    )

    #expect(resolved == nil)
}

// A connected MagSafe cable that is NOT delivering is just a cable. Declining
// here would leave both cards blank on an M1 Pro charging through a USB-C dock
// with a MagSafe lead also plugged in, which is the one machine this path
// exists for.
@Test func smcContractStillFiresWithAMagSafeCableMerelyAttached() {
    let magSafeAttachedIdle = PortState(
        id: 101,
        uuid: otherUUID,
        portType: .magSafe,
        ccConnected: true
    )

    let resolved = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort(id: 3), magSafeAttachedIdle],
        chargerNodes: [ChargerInput(portType: "MagSafe 3", portNumber: 1)],
        externalConnected: true
    )

    #expect(resolved?.portID == 3)
}

// A node existing under MagSafe proves nothing: this M5 publishes one with
// nothing plugged in.
@Test func smcContractStillFiresWithAnEmptyMagSafePort() {
    let magSafeEmpty = PortState(id: 101, uuid: otherUUID, portType: .magSafe, ccConnected: false)

    let resolved = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort(id: 3), magSafeEmpty],
        chargerNodes: [ChargerInput(portType: "MagSafe 3", portNumber: 1)],
        externalConnected: true
    )

    #expect(resolved?.portID == 3)
}

// The IOKit layer asks this before paying for the SMC read, and the attribution
// asks it again before trusting the answer. If the two ever disagree, one of
// them reads or discards data the other did not expect, so they share it.
@Test func macOSDescribesChargingIsAboutPublishedContracts() {
    #expect(SMCContractAttribution.macOSDescribesCharging(chargerNodes: []) == false)

    // A bare node is not enough on its own: that is the mid-negotiation case,
    // handled per-port rather than machine-wide.
    #expect(SMCContractAttribution.macOSDescribesCharging(
        chargerNodes: [ChargerInput(portType: "USB-C", portNumber: 1)]
    ) == false)

    // Nor is a node merely existing under MagSafe, for the reason above.
    #expect(SMCContractAttribution.macOSDescribesCharging(
        chargerNodes: [ChargerInput(portType: "MagSafe 3", portNumber: 1)]
    ) == false)

    // A winning contract anywhere does mean macOS has answered.
    #expect(SMCContractAttribution.macOSDescribesCharging(
        chargerNodes: [ChargerInput(portType: "USB-C", portNumber: 1,
                                    maxWatts: 60_000, hasWinningContract: true)]
    ) == true)
}

// A bare node means macOS is describing that port and simply has not settled on
// a contract yet. That is mid-negotiation, not the missing-node bug.
@Test func smcContractStaysQuietOnAPortThatHasABareNode() {
    let resolved = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort(id: 3)],
        chargerNodes: [ChargerInput(portType: "USB-C", portNumber: 3)],
        externalConnected: true
    )

    #expect(resolved == nil)
}

@Test func smcContractRejectsAnImplausibleContract() {
    // Below the 5 V floor every USB-C contract starts at.
    let lowVoltage = SMCContractAttribution.resolve(
        contracts: [contract(voltageMV: 3_300)],
        ports: [usbCPort()],
        chargerNodes: [],
        externalConnected: true
    )
    #expect(lowVoltage == nil)

    let noPower = SMCContractAttribution.resolve(
        contracts: [contract(powerMW: 0)],
        ports: [usbCPort()],
        chargerNodes: [],
        externalConnected: true
    )
    #expect(noPower == nil)
}

// A channel labelled "usb host" is the Mac sourcing power outward. Showing that
// as an incoming charge would invert the direction of the whole reading.
@Test func smcContractRejectsAnOutgoingChannel() {
    let resolved = SMCContractAttribution.resolve(
        contracts: [contract(label: "USB Host Port")],
        ports: [usbCPort()],
        chargerNodes: [],
        externalConnected: true
    )

    #expect(resolved == nil)
}

@Test func smcContractIgnoresMagSafeAndDisconnectedPorts() {
    let magSafe = PortState(id: 101, uuid: portUUID, portType: .magSafe, ccConnected: true)
    let onMagSafe = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [magSafe],
        chargerNodes: [],
        externalConnected: true
    )
    #expect(onMagSafe == nil)

    let onEmptyPort = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort(ccConnected: false)],
        chargerNodes: [],
        externalConnected: true
    )
    #expect(onEmptyPort == nil)
}

// Two candidates means the join is ambiguous, and naming the wrong port is
// worse than naming none.
@Test func smcContractDeclinesWhenTwoChannelsResolve() {
    let resolved = SMCContractAttribution.resolve(
        contracts: [contract(channel: 1), contract(channel: 2, uuid: otherUUIDNormalised)],
        ports: [usbCPort(id: 1), usbCPort(id: 2, uuid: otherUUID)],
        chargerNodes: [],
        externalConnected: true
    )

    #expect(resolved == nil)
}

@Test func smcContractCanBeSwitchedOff() {
    let resolved = SMCContractAttribution.resolve(
        contracts: [contract()],
        ports: [usbCPort()],
        chargerNodes: [],
        externalConnected: true,
        enabled: false
    )

    #expect(resolved == nil)
}

// MARK: - End to end through PortManager

// The reporter's shape: a 14" MacBook Pro charging at 100 W over USB-C with no
// power-source node anywhere. Before this path existed the port showed
// connected with no power at all.
@Test func portManagerShowsChargingOnAnM1ProWithNoPowerSourceNode() {
    let manager = PortManager()

    manager.applySnapshot(PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: portUUID, portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: otherUUID, portNumber: 2, portType: "USB-C")
        ],
        ccData: [
            CCInput(portNumber: 1, portType: "USB-C", active: true, cableProductType: "", cablePDRevision: 0)
        ],
        chargerData: [],
        chargingPower: ChargingPowerInput(
            systemPowerIn: 96_000,
            systemVoltageIn: 20_000,
            systemCurrentIn: 4_800,
            isCharging: true
        ),
        smcPortContracts: [contract()]
    ))

    let charging = manager.ports.first { $0.id == 1 }
    #expect(charging?.power?.direction == .incoming)
    #expect(charging?.power?.watts == 96.0)
    // Volts and amps come from the contract, the live draw from telemetry.
    #expect(charging?.power?.configuredVoltage == 20_000)
    #expect(charging?.power?.configuredCurrent == 5_000)
    #expect(charging?.primaryProtocol == .charging)

    // The other port is untouched.
    #expect(manager.ports.first { $0.id == 2 }?.power == nil)
}

// Every Mac that already publishes the node must behave exactly as before.
@Test func portManagerPrefersTheRealNodeOverTheSMCContract() {
    let manager = PortManager()

    manager.applySnapshot(PortManagerSnapshot(
        hpmPorts: [HPMPortInput(uuid: portUUID, portNumber: 1, portType: "USB-C")],
        ccData: [
            CCInput(portNumber: 1, portType: "USB-C", active: true, cableProductType: "", cablePDRevision: 0)
        ],
        chargerData: [
            ChargerInput(
                portType: "USB-C",
                portNumber: 1,
                maxWatts: 60_000,
                voltage: 15_000,
                maxCurrent: 3_000,
                hasWinningContract: true
            )
        ],
        chargingPower: ChargingPowerInput(
            systemPowerIn: 58_000,
            systemVoltageIn: 15_000,
            systemCurrentIn: 3_800,
            isCharging: true
        ),
        smcPortContracts: [contract()]
    ))

    let charging = manager.ports.first { $0.id == 1 }
    #expect(charging?.power?.configuredVoltage == 15_000)
    #expect(charging?.power?.configuredCurrent == 3_000)
}

// A bare node (macOS published the port but no PDO yet) must not be treated as
// a contract by the charger path either.
@Test func portManagerIgnoresABareChargerNode() {
    let manager = PortManager()

    manager.applySnapshot(PortManagerSnapshot(
        hpmPorts: [HPMPortInput(uuid: portUUID, portNumber: 1, portType: "USB-C")],
        ccData: [
            CCInput(portNumber: 1, portType: "USB-C", active: true, cableProductType: "", cablePDRevision: 0)
        ],
        chargerData: [ChargerInput(portType: "USB-C", portNumber: 1)],
        chargingPower: ChargingPowerInput(
            systemPowerIn: 96_000,
            systemVoltageIn: 20_000,
            systemCurrentIn: 4_800,
            isCharging: true
        )
    ))

    #expect(manager.ports.first { $0.id == 1 }?.power == nil)
}

// MARK: - The 5 V floor (DAR-247)

// The SMC does not always report a 5 V rail as exactly 5000. These are the real
// figures from the six machines in the probe corpus that report 4750, which a
// 5000 floor rejected outright: those Macs showed no charging power at all
// while drawing 15 W. Every one multiplies out exactly, and none of their
// channels was sourcing power outward.
@Test func aFiveVoltContractReportedLowIsStillACharge() {
    let realWorld = [
        (voltageMV: 4_750, currentMA: 3_000, powerMW: 14_250),  // M1 Pro, M2, M3, M5 Pro
        (voltageMV: 4_750, currentMA: 1_500, powerMW: 7_125),   // M1
        (voltageMV: 4_750, currentMA: 500, powerMW: 2_375),     // M3
    ]

    for figures in realWorld {
        let candidate = contract(
            powerMW: figures.powerMW,
            voltageMV: figures.voltageMV,
            currentMA: figures.currentMA
        )
        #expect(
            SMCContractAttribution.isPlausibleIncomingContract(candidate),
            "\(figures.voltageMV) mV at \(figures.currentMA) mA is a real 5 V charge"
        )
    }
}

// The label rule is what rejects the Mac sourcing power outward, not the floor.
// One of the six 4750 mV rows is labelled this way, and it must stay rejected
// now that the floor no longer happens to catch it.
//
// Asserting the rejection alone would prove nothing: it also passed under the
// old 5000 floor, which rejected the row before the label was ever consulted.
// So the same figures are asserted to pass WITHOUT the label first.
@Test func aLowVoltageChannelSourcingPowerOutwardIsStillRejected() {
    let figures = (powerMW: 14_250, voltageMV: 4_750, currentMA: 3_000)

    #expect(SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: figures.powerMW, voltageMV: figures.voltageMV, currentMA: figures.currentMA)
    ), "the label must be the only thing rejecting this")

    #expect(!SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: figures.powerMW, voltageMV: figures.voltageMV, currentMA: figures.currentMA, label: "usb host")
    ))
}

// A label is thin evidence of direction: only 1 of 463 corpus contracts carries
// one, so an outgoing channel is far likelier to be unlabelled. A measured
// outgoing draw on the same channel is not thin, and it is what closes the case
// lowering the floor would otherwise open.
@Test func anUnlabelledChannelFeedingAPeripheralIsRejected() {
    let figures = contract(powerMW: 14_250, voltageMV: 4_750, currentMA: 3_000)

    // Same channel, drawing nothing out: a charge.
    #expect(SMCContractAttribution.isPlausibleIncomingContract(
        figures,
        powerOut: SMCPortPowerInput(present: false, volts: 0, amps: 0, uuid: portUUIDNormalised)
    ))

    // Same channel, measurably sourcing 15 W: the Mac feeding something.
    #expect(!SMCContractAttribution.isPlausibleIncomingContract(
        figures,
        powerOut: SMCPortPowerInput(present: true, volts: 5.0, amps: 3.0, uuid: portUUIDNormalised)
    ))

    // Idle-channel noise must not read as sourcing.
    #expect(SMCContractAttribution.isPlausibleIncomingContract(
        figures,
        powerOut: SMCPortPowerInput(present: true, volts: 5.0, amps: 0.01, uuid: portUUIDNormalised)
    ))
}

// Both constants are load-bearing and neither was pinned: review showed the
// floor could drift from 4500 to 4000, and the tolerance from 2% to nearly 20%,
// without a single test noticing. These fix them to their documented values.
@Test func theVoltageFloorSitsWhereItIsDocumented() {
    #expect(SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: 13_500, voltageMV: 4_500, currentMA: 3_000)
    ), "4500 mV is the floor and must be accepted")

    #expect(!SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: 13_497, voltageMV: 4_499, currentMA: 3_000)
    ), "one millivolt below the floor must be rejected")
}

@Test func theConsistencyToleranceSitsWhereItIsDocumented() {
    // 1.9% out: inside the band.
    #expect(SMCContractAttribution.isInternallyConsistent(
        contract(powerMW: 100_000, voltageMV: 20_000, currentMA: 5_095)
    ))
    // 2.1% out: outside it.
    #expect(!SMCContractAttribution.isInternallyConsistent(
        contract(powerMW: 100_000, voltageMV: 20_000, currentMA: 5_105)
    ))
}

// The floor still has a job: nothing in the corpus sits between 0 and 4750, so
// anything under the tolerance band is a channel that did not read.
@Test func aVoltageBelowTheToleranceBandIsStillRejected() {
    #expect(!SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: 14_250, voltageMV: 3_300, currentMA: 4_318)
    ))
    #expect(!SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: 14_250, voltageMV: 0, currentMA: 3_000)
    ))
}

// Power, voltage and current are three independent SMC reads. A partial read
// pairs a plausible wattage with a voltage that does not multiply out, which is
// what actually distinguishes a half-read channel from a low-voltage charge.
@Test func figuresThatDoNotMultiplyOutAreRejected() {
    // Plausible voltage and a real-looking wattage, but they disagree: 20 V at
    // 5 A is 100 W, not 14.25 W.
    #expect(!SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: 14_250, voltageMV: 20_000, currentMA: 5_000)
    ))
    // A current that never landed cannot corroborate anything.
    #expect(!SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: 100_000, voltageMV: 20_000, currentMA: 0)
    ))
    // The SMC rounds each figure separately, so exact agreement is not required.
    #expect(SMCContractAttribution.isInternallyConsistent(
        contract(powerMW: 100_000, voltageMV: 20_000, currentMA: 4_950)
    ))
    #expect(!SMCContractAttribution.isInternallyConsistent(
        contract(powerMW: 100_000, voltageMV: 20_000, currentMA: 4_000)
    ))
}

// The real contracts already asserted elsewhere in this file must keep passing:
// this Mac's own 20 V / 4.7 A / 94 W, and the 100 W fixture used throughout.
@Test func ordinaryLaptopChargersStillPass() {
    #expect(SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: 94_000, voltageMV: 20_000, currentMA: 4_700)
    ))
    #expect(SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: 100_000, voltageMV: 20_000, currentMA: 5_000)
    ))
    // 28 V, the highest rail in the corpus.
    #expect(SMCContractAttribution.isPlausibleIncomingContract(
        contract(powerMW: 140_000, voltageMV: 28_000, currentMA: 5_000)
    ))
}
