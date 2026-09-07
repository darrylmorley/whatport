import Testing
@testable import WhatPortCore

// The join by elimination for a USB-C port whose HPM node publishes no UUID.
//
// One machine in the probe corpus (m2_macos27.0_i, an M2 laptop on macOS 27.0)
// publishes Port-USB-C@2 with a blank UUID while the SMC still publishes that
// port's UUID on D2. With exactly one unidentified port and exactly one SMC
// channel matching no port, only one pairing is available, so it can be made
// without guessing. Every other shape must refuse: a wrong UUID is worse than
// no UUID, because it would attribute another port's power to this one.
@Suite("HPM UUID join by elimination")
struct HPMUUIDEliminationTests {

    private static let portOneUUID = "DED58523-3D40-AFA6-9F47-046CFF0878FF"
    private static let magSafeUUID = "FCD58523-115C-EE9D-1143-1A1A67A71B46"
    private static let orphanUUID = "30ff8523ef7dffbfa44c20127a93e426"

    private static func usbC(_ number: Int, uuid: String) -> HPMPortInput {
        HPMPortInput(uuid: uuid, portNumber: number, portType: "USB-C")
    }

    private static func magSafe(_ number: Int, uuid: String) -> HPMPortInput {
        HPMPortInput(uuid: uuid, portNumber: number, portType: "MagSafe 3")
    }

    private static func channel(_ index: Int, uuid: String) -> SMCPortPowerInput {
        SMCPortPowerInput(present: true, volts: 5.0, amps: 0.5, uuid: uuid, channel: index)
    }

    private static func normalised(_ uuid: String) -> String {
        SMCContractAttribution.normalisedUUID(uuid)
    }

    @Test("One unidentified port and one unmatched UUID join")
    func oneAndOneJoins() {
        // The m2_macos27.0_i shape: two USB-C ports and a MagSafe, the second
        // USB-C blank, three SMC channels of which D2 matches nothing.
        let joined = PortManager.joinUnidentifiedPortByElimination(
            hpmPorts: [
                Self.usbC(1, uuid: Self.portOneUUID),
                Self.usbC(2, uuid: ""),
                Self.magSafe(1, uuid: Self.magSafeUUID)
            ],
            smcChannels: [
                Self.channel(1, uuid: Self.normalised(Self.portOneUUID)),
                Self.channel(2, uuid: Self.orphanUUID),
                Self.channel(3, uuid: Self.normalised(Self.magSafeUUID))
            ]
        )

        #expect(joined.count == 3)
        #expect(joined.first { $0.portNumber == 2 && !$0.isMagSafe }?.uuid == Self.orphanUUID)
        // The ports that already had a UUID keep it untouched.
        #expect(joined.first { $0.portNumber == 1 && !$0.isMagSafe }?.uuid == Self.portOneUUID)
        #expect(joined.first(where: \.isMagSafe)?.uuid == Self.magSafeUUID)
    }

    @Test("Two unidentified ports refuse to join")
    func twoUnidentifiedPortsRefuse() {
        let joined = PortManager.joinUnidentifiedPortByElimination(
            hpmPorts: [
                Self.usbC(1, uuid: ""),
                Self.usbC(2, uuid: "")
            ],
            smcChannels: [Self.channel(2, uuid: Self.orphanUUID)]
        )

        #expect(joined.allSatisfy { $0.uuid.isEmpty })
    }

    @Test("Two unmatched UUIDs refuse to join")
    func twoUnmatchedUUIDsRefuse() {
        let joined = PortManager.joinUnidentifiedPortByElimination(
            hpmPorts: [
                Self.usbC(1, uuid: Self.portOneUUID),
                Self.usbC(2, uuid: "")
            ],
            smcChannels: [
                Self.channel(1, uuid: Self.normalised(Self.portOneUUID)),
                Self.channel(2, uuid: Self.orphanUUID),
                Self.channel(3, uuid: Self.normalised(Self.magSafeUUID))
            ]
        )

        #expect(joined.first { $0.portNumber == 2 }?.uuid == "")
    }

    @Test("No SMC channel leaves the port unidentified")
    func noChannelsLeavesThePortUnidentified() {
        let joined = PortManager.joinUnidentifiedPortByElimination(
            hpmPorts: [
                Self.usbC(1, uuid: Self.portOneUUID),
                Self.usbC(2, uuid: "")
            ],
            smcChannels: []
        )

        #expect(joined.count == 2)
        #expect(joined.first { $0.portNumber == 2 }?.uuid == "")
    }

    @Test("A spare channel whose owner is missing from the roster is refused")
    func spareChannelOfAMissingPortIsRefused() {
        // The roster lists no MagSafe port at all, so MagSafe's own channel
        // reads as spare and the blank USB-C port would adopt its identity.
        // Nothing in the channel says whose it is, but the D-index does not
        // line up with the blank port's place among the USB-C ports (offset 1
        // wants D2, the spare is D3), and that is enough to refuse.
        let joined = PortManager.joinUnidentifiedPortByElimination(
            hpmPorts: [
                Self.usbC(1, uuid: Self.portOneUUID),
                Self.usbC(2, uuid: "")
            ],
            smcChannels: [
                Self.channel(1, uuid: Self.normalised(Self.portOneUUID)),
                Self.channel(3, uuid: Self.normalised(Self.magSafeUUID))
            ]
        )

        #expect(joined.first { $0.portNumber == 2 }?.uuid == "")
    }

    @Test("Fewer channels than ports refuses, even with one spare")
    func fewerChannelsThanPortsRefuses() {
        // Three ports and two channels: a port somewhere has no channel, so
        // the spare one cannot be shown to belong to the blank port rather
        // than to whichever port went unrepresented.
        let joined = PortManager.joinUnidentifiedPortByElimination(
            hpmPorts: [
                Self.usbC(1, uuid: Self.portOneUUID),
                Self.usbC(2, uuid: ""),
                Self.magSafe(1, uuid: Self.magSafeUUID)
            ],
            smcChannels: [
                Self.channel(1, uuid: Self.normalised(Self.portOneUUID)),
                Self.channel(2, uuid: Self.orphanUUID)
            ]
        )

        #expect(joined.first { $0.portNumber == 2 && !$0.isMagSafe }?.uuid == "")
    }

    @Test("MagSafe never takes part in the elimination")
    func magSafeNeverTakesPart() {
        // A blank MagSafe port with one unmatched channel beside it is exactly
        // the one-and-one shape, and it still must not join: MagSafe power is
        // attributed from the node, never from an SMC power-OUT channel.
        let joined = PortManager.joinUnidentifiedPortByElimination(
            hpmPorts: [
                Self.usbC(1, uuid: Self.portOneUUID),
                Self.magSafe(1, uuid: "")
            ],
            smcChannels: [
                Self.channel(1, uuid: Self.normalised(Self.portOneUUID)),
                Self.channel(2, uuid: Self.orphanUUID)
            ]
        )

        #expect(joined.first(where: \.isMagSafe)?.uuid == "")
    }

    @Test("The recovered port keeps its roster place and takes its SMC power")
    func recoveredPortIsCorrelatedAndPowered() {
        let manager = PortManager()

        manager.applySnapshot(PortManagerSnapshot(
            hpmPorts: [
                Self.usbC(1, uuid: Self.portOneUUID),
                Self.usbC(2, uuid: "")
            ],
            smcPortPower: [
                Self.channel(1, uuid: Self.normalised(Self.portOneUUID)),
                SMCPortPowerInput(present: true, volts: 5.0, amps: 1.0, uuid: Self.orphanUUID, channel: 2)
            ]
        ))

        #expect(manager.ports.count == 2)
        let recovered = manager.ports.first { $0.id == 2 }
        #expect(recovered?.uuid == Self.orphanUUID)
        #expect(recovered?.power?.watts == 5.0)
        #expect(recovered?.power?.direction == .outgoing)
    }

    @Test("A port that stays unidentified carries no UUID at all")
    func unjoinedPortCarriesNoUUID() {
        let manager = PortManager()

        manager.applySnapshot(PortManagerSnapshot(
            hpmPorts: [
                Self.usbC(1, uuid: Self.portOneUUID),
                Self.usbC(2, uuid: "")
            ],
            smcPortPower: []
        ))

        #expect(manager.ports.count == 2)
        // Empty is not an identity: it must never reach the joins as one.
        #expect(manager.ports.first { $0.id == 2 }?.uuid == nil)
    }
}
