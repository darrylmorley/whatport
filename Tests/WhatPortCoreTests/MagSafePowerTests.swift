import Testing
@testable import WhatPortCore

// MagSafe power-IN attribution. The rule is "is this connector the one
// delivering", never "is the battery charging": a Mac sitting at 100% on
// MagSafe is still drawing its whole running load through that charger.

private func magSafeSnapshot(
    magSafeConnected: Bool = true,
    isCharging: Bool,
    fullyCharged: Bool = false,
    systemPowerIn: Int = 5_600,
    chargerData: [ChargerInput] = [],
    usbCActive: Bool = false
) -> PortManagerSnapshot {
    PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: "AAAA-1", portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: "BBBB-1", portNumber: 1, portType: "MagSafe 3")
        ],
        ccData: [
            CCInput(portNumber: 1, portType: "USB-C", active: usbCActive),
            CCInput(portNumber: 1, portType: "MagSafe 3", active: magSafeConnected)
        ],
        chargerData: chargerData,
        chargingPower: ChargingPowerInput(
            systemPowerIn: systemPowerIn,
            systemVoltageIn: 20_000,
            systemCurrentIn: 280,
            isCharging: isCharging,
            fullyCharged: fullyCharged
        )
    )
}

private let magSafeContract = ChargerInput(
    portType: "MagSafe 3",
    portNumber: 1,
    maxWatts: 96_000,
    voltage: 20_000,
    maxCurrent: 4_800,
    hasWinningContract: true
)

// What ChargerReader produces when macOS publishes no winning option and it
// falls back to the highest entry in PowerSourceOptions: the adapter's
// capability, not an agreement.
private let magSafeAdvertisedOnly = ChargerInput(
    portType: "MagSafe 3",
    portNumber: 1,
    maxWatts: 96_000,
    voltage: 20_000,
    maxCurrent: 4_800,
    hasWinningContract: false
)

private func magSafePort(_ manager: PortManager) -> PortState? {
    manager.ports.first { $0.portType == .magSafe }
}

// The bug: at 100% the port showed connected with no power at all, while the
// charger carried the machine's running load. 312 of 318 corpus machines that
// are plugged in and not charging still report a positive systemPowerIn.
@Test func magSafeShowsPowerWhenTheBatteryIsFull() {
    let manager = PortManager()
    manager.applySnapshot(magSafeSnapshot(
        isCharging: false,
        fullyCharged: true,
        chargerData: [magSafeContract]
    ))

    let port = magSafePort(manager)
    #expect(port?.power?.direction == .incoming)
    #expect(port?.power?.watts == 5.6)
    #expect(manager.chargingStatus == .fullyCharged)
}

// Optimised charging holding at 80% reads the same way as a full battery.
@Test func magSafeShowsPowerWhileChargingIsHeldForBatteryHealth() {
    let manager = PortManager()
    manager.applySnapshot(PortManagerSnapshot(
        ccData: [CCInput(portNumber: 1, portType: "MagSafe 3", active: true)],
        chargerData: [magSafeContract],
        chargingPower: ChargingPowerInput(
            systemPowerIn: 7_200,
            systemVoltageIn: 20_000,
            systemCurrentIn: 360,
            isCharging: false,
            notChargingReason: 1 << 24
        )
    ))

    #expect(magSafePort(manager)?.power?.watts == 7.2)
    #expect(manager.chargingStatus == .onHoldForHealth)
}

@Test func magSafeStillShowsPowerWhileActivelyCharging() {
    let manager = PortManager()
    manager.applySnapshot(magSafeSnapshot(isCharging: true, chargerData: [magSafeContract]))

    #expect(magSafePort(manager)?.power?.watts == 5.6)
}

// systemPowerIn is the machine's total DC-in, so it belongs to whichever
// connector is delivering. A MagSafe cable left attached while USB-C does the
// charging must not repeat the same watts on a second card.
@Test func magSafeStaysBlankWhenUSBCHoldsTheContract() {
    let manager = PortManager()
    manager.applySnapshot(magSafeSnapshot(
        isCharging: true,
        chargerData: [
            ChargerInput(portType: "USB-C", portNumber: 1, maxWatts: 60_000,
                         voltage: 20_000, maxCurrent: 3_000, hasWinningContract: true)
        ],
        usbCActive: true
    ))

    #expect(magSafePort(manager)?.power == nil)
    // The USB-C port is the one that gets it.
    #expect(manager.ports.first { $0.id == 1 }?.power?.direction == .incoming)
}

// Never observed in 532 corpus machines (macOS negotiates on one connector at
// a time), but if it ever happens the figure must land on one card, not two.
// totalWattsIn sums every incoming port, so double attribution would also
// double the menu bar total.
@Test func systemPowerInIsNeverAttributedToTwoPortsAtOnce() {
    let manager = PortManager()
    manager.applySnapshot(magSafeSnapshot(
        isCharging: true,
        chargerData: [
            magSafeContract,
            ChargerInput(portType: "USB-C", portNumber: 1, maxWatts: 60_000,
                         voltage: 20_000, maxCurrent: 3_000, hasWinningContract: true)
        ],
        usbCActive: true
    ))

    let incoming = manager.ports.filter { $0.power?.direction == .incoming }
    #expect(incoming.count == 1)
    #expect(incoming.first?.portType == .usbC)
    #expect(manager.totalWattsIn == 5.6)
}

// The M1 Pro desk setup: charging over a USB-C dock with a MagSafe cable also
// plugged in. That silicon publishes no USB-C power-source node at all, so
// "no USB-C contract" must not be read as "USB-C is not charging". The SMC
// contract is the evidence that it is.
@Test func magSafeDefersToUSBCWhenOnlyTheSMCKnowsUSBCIsCharging() {
    let manager = PortManager()
    let usbCUUID = "CCCC1111-2222-3333-4444-555566667777"

    manager.applySnapshot(PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: usbCUUID, portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: "BBBB-1", portNumber: 1, portType: "MagSafe 3")
        ],
        ccData: [
            CCInput(portNumber: 1, portType: "USB-C", active: true),
            CCInput(portNumber: 1, portType: "MagSafe 3", active: true)
        ],
        chargerData: [],
        chargingPower: ChargingPowerInput(
            systemPowerIn: 60_000,
            systemVoltageIn: 20_000,
            systemCurrentIn: 3_000,
            isCharging: true
        ),
        smcPortContracts: [
            SMCPortContractInput(
                channel: 2,
                uuid: usbCUUID.replacingOccurrences(of: "-", with: "").lowercased(),
                powerMW: 90_000,
                voltageMV: 20_000,
                currentMA: 4_500,
                label: "pd charger"
            )
        ]
    ))

    // MagSafe is merely attached. It must not claim the machine's whole draw.
    #expect(manager.ports.first { $0.portType == .magSafe }?.power == nil)

    // And USB-C must actually get it. Asserting only "at most one incoming"
    // was too weak: both cards blank satisfies that too, which is exactly the
    // silent-nothing state this setup used to fall into.
    let usbC = manager.ports.first { $0.id == 1 }
    #expect(usbC?.power?.direction == .incoming)
    #expect(usbC?.power?.configuredVoltage == 20_000)
    #expect(manager.totalWattsIn == 60.0)
    #expect(manager.ports.filter { $0.power?.direction == .incoming }.count == 1)
}

// The other side of that deferral: a MagSafe port holding its own winning
// contract is macOS answering about this very connector, and an unrelated
// USB-C peripheral's SMC channel must not blank it.
@Test func magSafeKeepsItsOwnContractDespiteUnrelatedUSBCSMCEvidence() {
    let manager = PortManager()
    let usbCUUID = "DDDD1111-2222-3333-4444-555566667777"

    manager.applySnapshot(PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: usbCUUID, portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: "BBBB-1", portNumber: 1, portType: "MagSafe 3")
        ],
        ccData: [
            CCInput(portNumber: 1, portType: "USB-C", active: true),
            CCInput(portNumber: 1, portType: "MagSafe 3", active: true)
        ],
        chargerData: [magSafeContract],
        chargingPower: ChargingPowerInput(
            systemPowerIn: 5_600,
            systemVoltageIn: 20_000,
            systemCurrentIn: 280,
            isCharging: false,
            fullyCharged: true
        ),
        smcPortContracts: [
            SMCPortContractInput(
                channel: 2,
                uuid: usbCUUID.replacingOccurrences(of: "-", with: "").lowercased(),
                powerMW: 15_000,
                voltageMV: 9_000,
                currentMA: 1_670,
                label: "pd charger"
            )
        ]
    ))

    #expect(magSafePort(manager)?.power?.watts == 5.6)
    #expect(manager.ports.filter { $0.power?.direction == .incoming }.count == 1)
    #expect(manager.totalWattsIn == 5.6)
}

// MagSafe genuinely delivering while publishing no usable node, with a USB-C
// dock also negotiating. The SMC publishes a contract channel for the MagSafe
// port on 118 corpus machines, and that is the only thing distinguishing this
// from the dock-is-charging case above.
@Test func magSafeKeepsPowerWhenOnlyTheSMCKnowsMagSafeIsDelivering() {
    let manager = PortManager()
    let magSafeUUID = "EEEE1111-2222-3333-4444-555566667777"
    let usbCUUID = "FFFF1111-2222-3333-4444-555566667777"
    func normalised(_ s: String) -> String {
        s.replacingOccurrences(of: "-", with: "").lowercased()
    }

    manager.applySnapshot(PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: usbCUUID, portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: magSafeUUID, portNumber: 1, portType: "MagSafe 3")
        ],
        ccData: [
            CCInput(portNumber: 1, portType: "USB-C", active: true),
            CCInput(portNumber: 1, portType: "MagSafe 3", active: true)
        ],
        chargerData: [],
        chargingPower: ChargingPowerInput(
            systemPowerIn: 96_000,
            systemVoltageIn: 20_000,
            systemCurrentIn: 4_800,
            isCharging: false,
            fullyCharged: true
        ),
        smcPortContracts: [
            SMCPortContractInput(channel: 1, uuid: normalised(magSafeUUID),
                                 powerMW: 96_000, voltageMV: 20_000, currentMA: 4_800),
            SMCPortContractInput(channel: 2, uuid: normalised(usbCUUID),
                                 powerMW: 15_000, voltageMV: 9_000, currentMA: 1_670)
        ]
    ))

    #expect(magSafePort(manager)?.power?.watts == 96.0)
    #expect(manager.ports.filter { $0.power?.direction == .incoming }.count == 1)
}

// The contract survives the not-charging state on only 73 of 84 corpus
// machines, so MagSafe being the only charger has to be enough on its own.
@Test func magSafeShowsPowerWithNoContractPublishedAtAll() {
    let manager = PortManager()
    manager.applySnapshot(magSafeSnapshot(isCharging: false, fullyCharged: true))

    #expect(magSafePort(manager)?.power?.watts == 5.6)
}

@Test func magSafeStaysBlankWhenNothingIsPluggedIn() {
    let manager = PortManager()
    manager.applySnapshot(magSafeSnapshot(
        magSafeConnected: false,
        isCharging: false,
        chargerData: [magSafeContract]
    ))

    #expect(magSafePort(manager)?.power == nil)
}

@Test func magSafeStaysBlankWhenNoPowerIsFlowing() {
    let manager = PortManager()
    manager.applySnapshot(magSafeSnapshot(
        isCharging: false,
        systemPowerIn: 0,
        chargerData: [magSafeContract]
    ))

    #expect(magSafePort(manager)?.power == nil)
}

// The Contract row used to repeat the measured input, reporting a measurement
// as an agreement. It now carries the negotiated figures, or nothing.
@Test func magSafeContractRowCarriesTheNegotiatedFigures() {
    let manager = PortManager()
    manager.applySnapshot(magSafeSnapshot(isCharging: true, chargerData: [magSafeContract]))

    let power = magSafePort(manager)?.power
    #expect(power?.configuredVoltage == 20_000)
    #expect(power?.configuredCurrent == 4_800)

    // With no contract published, the row hides rather than relabelling the
    // measured figure shown next to it.
    let noContract = PortManager()
    noContract.applySnapshot(magSafeSnapshot(isCharging: true))
    #expect(magSafePort(noContract)?.power?.configuredVoltage == 0)
    #expect(magSafePort(noContract)?.power?.configuredCurrent == 0)
}

// An advertised PDO is what the adapter can offer, not what was agreed. The
// wattage still shows; only the "Contract" row stays empty, because filling it
// from a capability would report it as an agreement.
@Test func magSafeAdvertisedPDOIsNotShownAsAContract() {
    let manager = PortManager()
    manager.applySnapshot(magSafeSnapshot(
        isCharging: false,
        fullyCharged: true,
        chargerData: [magSafeAdvertisedOnly]
    ))

    let power = magSafePort(manager)?.power
    #expect(power?.watts == 5.6)
    #expect(power?.configuredVoltage == 0)
    #expect(power?.configuredCurrent == 0)
}
