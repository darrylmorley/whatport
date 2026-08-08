import Testing
@testable import WhatPortCore

@Test func portManagerAppliesSnapshotWithIdlePorts() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [
            PhyInput(phyID: 0),
            PhyInput(phyID: 1),
            PhyInput(phyID: 2)
        ],
        tbData: [
            ThunderboltInput(socketID: 1),
            ThunderboltInput(socketID: 2),
            ThunderboltInput(socketID: 4)
        ]
    )

    manager.applySnapshot(snapshot)

    #expect(manager.ports.count == 3)
    #expect(manager.portCount == 3)
    #expect(manager.activePortCount == 0)
    #expect(manager.ports[0].id == 1)
    #expect(manager.ports[1].id == 2)
    #expect(manager.ports[2].id == 4)
}

@Test func portManagerCorrelatesTBActivePort() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [
            PhyInput(phyID: 0, lane0Transport: "CIO", lane0PowerLevel: "on", lane1Transport: "CIO", lane1PowerLevel: "on"),
            PhyInput(phyID: 1),
            PhyInput(phyID: 2)
        ],
        tbData: [
            ThunderboltInput(socketID: 1, currentLinkWidth: 2, currentLinkSpeed: 4),
            ThunderboltInput(socketID: 2),
            ThunderboltInput(socketID: 4)
        ]
    )

    manager.applySnapshot(snapshot)

    let port1 = manager.ports[0]
    #expect(port1.isActive)
    #expect(port1.lane0.transport == .thunderbolt)
    #expect(port1.lane1.transport == .thunderbolt)
    #expect(port1.thunderboltLink != nil)
    #expect(port1.thunderboltLink?.generation == .tb4)
    #expect(port1.thunderboltLink?.perLaneGbps == 20)
    #expect(port1.thunderboltLink?.txLanes == 2)
    #expect(port1.thunderboltLink?.totalGbps == 40)
}

@Test func portManagerCorrelatesPowerData() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0)],
        tbData: [ThunderboltInput(socketID: 1)],
        powerData: [
            PowerInput(
                portIndex: 1,
                watts: 5900,
                current: 113,
                adapterVoltage: 5200,
                configuredVoltage: 5000,
                configuredCurrent: 1500,
                vconnCurrent: 14,
                vconnPower: 350,
                vconnMaxCurrent: 1000
            )
        ],
        powerMeteringAvailable: true
    )

    manager.applySnapshot(snapshot)

    let port = manager.ports[0]
    #expect(port.power != nil)
    #expect(port.power?.watts == 5.9)
    #expect(port.power?.current == 113)
    #expect(port.power?.voltage == 5200)
    // VConn power/current round-trip through PowerInput -> PortPower.
    #expect(port.power?.vconnPower == 350)
    #expect(port.power?.vconnMaxCurrent == 1000)
    // Read straight from PowerOutDetails, macOS's own measurement.
    #expect(port.power?.contractIsEstimated == false)
    #expect(manager.powerMeteringAvailable)
}

@Test func portManagerTracksPowerHistory() {
    let manager = PortManager()

    for i in 0..<65 {
        let snapshot = PortManagerSnapshot(
            phyData: [PhyInput(phyID: 0)],
            tbData: [ThunderboltInput(socketID: 1)],
            powerData: [PowerInput(portIndex: 1, watts: i * 1000)]
        )
        manager.applySnapshot(snapshot)
    }

    let history = manager.powerHistory[1] ?? []
    #expect(history.count == 60) // capped at maxPowerSamples
    #expect(history.last?.watts == 64.0) // last sample: 64000 mW = 64.0W
}

@Test func portManagerDeduplicatesTBAdapters() {
    let manager = PortManager()

    // Two TB adapters for same socket (one per lane), different widths
    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0)],
        tbData: [
            ThunderboltInput(socketID: 1, currentLinkWidth: 1, currentLinkSpeed: 4),
            ThunderboltInput(socketID: 1, currentLinkWidth: 2, currentLinkSpeed: 4)
        ]
    )

    manager.applySnapshot(snapshot)

    #expect(manager.ports.count == 1)
    #expect(manager.ports[0].thunderboltLink?.txLanes == 2) // picked the wider one
}

// Mirrors real M4 Pro hardware: 4 PHYs, 3 ports.
// PHY 0 and PHY 2 both map to port 1. PHY 2 is idle, PHY 0 is active.
// Without direct mapping, positional logic would wrongly assign PHY 2 to port 4.
@Test func portManagerUsesDirectPhyToPortMapping() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [
            PhyInput(phyID: 0, portNumber: 1, lane0Transport: "USB3", lane0PowerLevel: "on"),
            PhyInput(phyID: 1, portNumber: 2, lane0Transport: "DisplayPort", lane0PowerLevel: "on"),
            PhyInput(phyID: 2, portNumber: 1), // duplicate port 1, idle
            PhyInput(phyID: 3, portNumber: 4)
        ],
        tbData: [
            ThunderboltInput(socketID: 1),
            ThunderboltInput(socketID: 2),
            ThunderboltInput(socketID: 4)
        ]
    )

    manager.applySnapshot(snapshot)

    // Should have 3 ports (from TB socket IDs), not 4
    #expect(manager.ports.count == 3)

    // Port 1: should get PHY 0's USB3 data (active wins over PHY 2's idle)
    let port1 = manager.ports[0]
    #expect(port1.id == 1)
    #expect(port1.lane0.transport == .usb)

    // Port 2: should get PHY 1's DisplayPort data
    let port2 = manager.ports[1]
    #expect(port2.id == 2)
    #expect(port2.lane0.transport == .displayPort)

    // Port 4: should get PHY 3's idle data (not PHY 2)
    let port3 = manager.ports[2]
    #expect(port3.id == 4)
    #expect(!port3.isActive)
}

// When port-number is not available (0), fall back to positional mapping.
// This is the legacy behavior for machines where device tree doesn't
// expose port-number on atc-phy nodes.
@Test func portManagerFallsBackToPositionalMapping() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [
            PhyInput(phyID: 0, lane0Transport: "CIO", lane0PowerLevel: "on"),
            PhyInput(phyID: 1)
        ],
        tbData: [
            ThunderboltInput(socketID: 1, currentLinkWidth: 2, currentLinkSpeed: 4),
            ThunderboltInput(socketID: 2)
        ]
    )

    manager.applySnapshot(snapshot)

    #expect(manager.ports.count == 2)
    // Positional: PHY 0 -> socket 1, PHY 1 -> socket 2
    #expect(manager.ports[0].id == 1)
    #expect(manager.ports[0].lane0.transport == .thunderbolt)
    #expect(manager.ports[1].id == 2)
    #expect(!manager.ports[1].isActive)
}

// When duplicate PHYs map to the same port, the one with active transport
// should be selected, regardless of phyID order.
@Test func portManagerDedupPicksActivePhy() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [
            PhyInput(phyID: 0, portNumber: 1), // idle
            PhyInput(phyID: 2, portNumber: 1, lane0Transport: "CIO", lane0PowerLevel: "on") // active
        ],
        tbData: [
            ThunderboltInput(socketID: 1, currentLinkWidth: 2, currentLinkSpeed: 4)
        ]
    )

    manager.applySnapshot(snapshot)

    #expect(manager.ports.count == 1)
    #expect(manager.ports[0].lane0.transport == .thunderbolt) // got the active PHY
}

// MagSafe and USB-C port 1 share ParentBuiltInPortNumber = 1.
// MagSafe must not pollute USB-C port state, and should appear as its own entry.
@Test func portManagerSeparatesMagSafeFromUSBC() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [
            PhyInput(phyID: 0, portNumber: 1),
            PhyInput(phyID: 1, portNumber: 2)
        ],
        tbData: [
            ThunderboltInput(socketID: 1),
            ThunderboltInput(socketID: 2)
        ],
        ccData: [
            CCInput(portNumber: 1, portType: "USB-C", active: false),
            CCInput(portNumber: 2, portType: "USB-C", active: true),
            CCInput(portNumber: 1, portType: "MagSafe 3", active: true)
        ]
    )

    manager.applySnapshot(snapshot)

    // 2 USB-C ports + 1 MagSafe = 3 total
    #expect(manager.ports.count == 3)

    // USB-C port 1: CC inactive (not contaminated by MagSafe)
    let usbcPort1 = manager.ports[0]
    #expect(usbcPort1.id == 1)
    #expect(usbcPort1.portType == .usbC)
    #expect(!usbcPort1.ccConnected)
    #expect(!usbcPort1.isActive)

    // USB-C port 2: CC active
    let usbcPort2 = manager.ports[1]
    #expect(usbcPort2.id == 2)
    #expect(usbcPort2.ccConnected)

    // MagSafe: shown as its own port, active
    let magSafe = manager.ports[2]
    #expect(magSafe.portType == .magSafe)
    #expect(magSafe.ccConnected)
    #expect(magSafe.isActive)
    #expect(magSafe.primaryProtocol == .charging)
}

// The headline win of HPM-anchored correlation: USB-C@1 and MagSafe@1 share
// the same "@N" number but get distinct stable UUIDs, so data can never bleed
// between them. UUIDs taken from a real M5 MacBook Pro.
@Test func portManagerStampsDistinctUUIDsForCollidingPortNumbers() {
    let manager = PortManager()

    let usbc1UUID = "6230AF2D-EE59-552E-E28A-652CCC0E7B11"
    let usbc2UUID = "492BAF2D-4561-2E29-5FFE-BD2ADE023D0F"
    let magSafeUUID = "7C30AF2D-CC71-7D20-5287-C77DB8476817"

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: usbc1UUID, portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: usbc2UUID, portNumber: 2, portType: "USB-C"),
            HPMPortInput(uuid: magSafeUUID, portNumber: 1, portType: "MagSafe 3"),
        ],
        phyData: [
            PhyInput(phyID: 0, portNumber: 1),
            PhyInput(phyID: 1, portNumber: 2),
        ],
        tbData: [
            ThunderboltInput(socketID: 1),
            ThunderboltInput(socketID: 2),
        ],
        ccData: [
            CCInput(portNumber: 1, portType: "USB-C", active: false),
            CCInput(portNumber: 2, portType: "USB-C", active: true),
            CCInput(portNumber: 1, portType: "MagSafe 3", active: true),
        ]
    )

    manager.applySnapshot(snapshot)

    let usbc1 = manager.ports.first { $0.id == 1 && $0.portType == .usbC }
    let magSafe = manager.ports.first { $0.portType == .magSafe }

    #expect(usbc1?.uuid == usbc1UUID)
    #expect(magSafe?.uuid == magSafeUUID)
    // Same @N = 1, different physical port, different identity.
    #expect(usbc1?.uuid != magSafe?.uuid)
}

// SMC per-port power-OUT is joined to ports by UUID (the channel's DxUI = the
// port's HPM UUID), not by the SMC D-index. The HPM UUID is uppercase with
// dashes; the SMC form is lowercase without. The join must normalise both.
@Test func portManagerJoinsSMCPowerByUUID() {
    let manager = PortManager()

    // Real M5 UUIDs. Port 4's HPM UUID, and its SMC DxUI form (dash-stripped,
    // lowercase) — note the SMC channel for this port is D3, not D4.
    let port4HPM = "17BD562D-D913-3441-0CD9-435CAC6CFA51"
    let port4SMC = "17bd562dd91334410cd9435cac6cfa51"

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: "6230AF2D-EE59-552E-E28A-652CCC0E7B11", portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: "492BAF2D-4561-2E29-5FFE-BD2ADE023D0F", portNumber: 2, portType: "USB-C"),
            HPMPortInput(uuid: port4HPM, portNumber: 4, portType: "USB-C"),
        ],
        phyData: [
            PhyInput(phyID: 0, portNumber: 1),
            PhyInput(phyID: 1, portNumber: 2),
            PhyInput(phyID: 2, portNumber: 4),
        ],
        smcPortPower: [
            SMCPortPowerInput(present: true, volts: 5.1, amps: 2.0, uuid: port4SMC),
        ]
    )

    manager.applySnapshot(snapshot)

    let port4 = manager.ports.first { $0.id == 4 }
    let port1 = manager.ports.first { $0.id == 1 }

    // Power lands on port 4 (matched by UUID), not on port 1, and not on a
    // phantom "port 3" from the SMC D-index.
    #expect(port4?.power?.watts == 5.1 * 2.0)
    #expect(port4?.power?.voltage == 5100)
    #expect(port4?.power?.current == 2000)
    #expect(port1?.power == nil)
    #expect(manager.ports.contains { $0.id == 3 } == false)
}

// A channel at 0 W (nothing drawing) must not attach power.
@Test func portManagerIgnoresZeroWattSMCChannel() {
    let manager = PortManager()
    let uuid = "6230AF2D-EE59-552E-E28A-652CCC0E7B11"
    let snapshot = PortManagerSnapshot(
        hpmPorts: [HPMPortInput(uuid: uuid, portNumber: 1, portType: "USB-C")],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        smcPortPower: [
            SMCPortPowerInput(present: false, volts: 0, amps: 0,
                              uuid: uuid.replacingOccurrences(of: "-", with: "").lowercased()),
        ]
    )

    manager.applySnapshot(snapshot)

    #expect(manager.ports.first { $0.id == 1 }?.power == nil)
}

// The SMC is the primary per-port source. Where a channel resolves to a port,
// its live watts/volts/amps override the (frozen) PowerOutDetails reading, but
// the PD contract from PowerOutDetails is carried over since the SMC lacks it.
@Test func portManagerSMCOverridesPowerOutDetailsButKeepsContract() {
    let manager = PortManager()
    let uuid = "6230AF2D-EE59-552E-E28A-652CCC0E7B11"
    let smcUUID = uuid.replacingOccurrences(of: "-", with: "").lowercased()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [HPMPortInput(uuid: uuid, portNumber: 1, portType: "USB-C")],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        powerData: [
            // Frozen PowerOutDetails reading: 5 W at 9 V, with a 20 V / 3 A contract.
            PowerInput(
                portIndex: 1,
                watts: 5000,
                adapterVoltage: 9000,
                configuredVoltage: 20000,
                configuredCurrent: 3000,
                vconnCurrent: 150
            ),
        ],
        smcPortPower: [
            // Live SMC channel: 30 W (15 V x 2 A).
            SMCPortPowerInput(present: true, volts: 15.0, amps: 2.0, uuid: smcUUID),
        ]
    )

    manager.applySnapshot(snapshot)
    let port1 = manager.ports.first { $0.id == 1 }

    // Live draw comes from the SMC.
    #expect(port1?.power?.watts == 30.0)
    #expect(port1?.power?.voltage == 15000)
    #expect(port1?.power?.current == 2000)
    #expect(port1?.power?.direction == .outgoing)
    // PD contract is carried over from PowerOutDetails.
    #expect(port1?.power?.configuredVoltage == 20000)
    #expect(port1?.power?.configuredCurrent == 3000)
    #expect(port1?.power?.vconnCurrent == 150)
}

// On a port with a PowerOutDetails reading but no resolving SMC channel (M1/M2,
// or any unresolved port), the PowerOutDetails reading stands unchanged.
@Test func portManagerKeepsPowerOutDetailsWhenNoSMCChannelResolves() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [HPMPortInput(uuid: "6230AF2D-EE59-552E-E28A-652CCC0E7B11", portNumber: 1, portType: "USB-C")],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        powerData: [
            PowerInput(portIndex: 1, watts: 5000, adapterVoltage: 9000,
                       configuredVoltage: 20000, configuredCurrent: 3000),
        ],
        smcPortPower: [
            // Resolves to a different port's UUID, so port 1 is untouched.
            SMCPortPowerInput(present: true, volts: 5.0, amps: 1.0,
                              uuid: "ffffffffffffffffffffffffffffffff"),
        ]
    )

    manager.applySnapshot(snapshot)
    let port1 = manager.ports.first { $0.id == 1 }

    #expect(port1?.power?.watts == 5.0)
    #expect(port1?.power?.voltage == 9000)   // adapterVoltage, untouched by SMC
    #expect(port1?.power?.configuredVoltage == 20000)
}

// The SMC measures power OUT, so it must never override an incoming (charger)
// reading on a charging port, even when a channel resolves to that port.
@Test func portManagerSMCDoesNotOverrideIncomingChargerPower() {
    let manager = PortManager()
    let uuid = "6230AF2D-EE59-552E-E28A-652CCC0E7B11"
    let smcUUID = uuid.replacingOccurrences(of: "-", with: "").lowercased()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [HPMPortInput(uuid: uuid, portNumber: 1, portType: "USB-C")],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        ccData: [CCInput(portNumber: 1, portType: "USB-C", active: true)],
        chargerData: [ChargerInput(portType: "USB-C", portNumber: 1, maxWatts: 100000, voltage: 20000, maxCurrent: 5000, hasWinningContract: true)],
        chargingPower: ChargingPowerInput(systemPowerIn: 60000, systemVoltageIn: 20000,
                                          systemCurrentIn: 3000, isCharging: true),
        smcPortPower: [
            SMCPortPowerInput(present: true, volts: 5.0, amps: 1.0, uuid: smcUUID),
        ]
    )

    manager.applySnapshot(snapshot)
    let port1 = manager.ports.first { $0.id == 1 }

    // The charger (incoming) reading stands; the SMC's outgoing 5 W is ignored.
    #expect(port1?.power?.direction == .incoming)
    #expect(port1?.power?.watts == 60.0)
}

// HPM health data flows through to PortState.health; a port with no
// overcurrent and no LDCM error is healthy (usage counts aside).
@Test func portManagerStampsHealthyPortFromHPMData() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(
                uuid: "6230AF2D-EE59-552E-E28A-652CCC0E7B11",
                portNumber: 1,
                portType: "USB-C",
                overcurrentCount: 0,
                plugEventCount: 12,
                connectionCount: 34,
                authorizationStatus: "Authorized",
                ldcmStatus: "No Error"
            )
        ],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)]
    )

    manager.applySnapshot(snapshot)

    let port = manager.ports.first { $0.id == 1 }
    #expect(port?.health != nil)
    #expect(port?.health?.overcurrentCount == 0)
    #expect(port?.health?.isHealthy == true)
}

// A port with overcurrent events is unhealthy.
@Test func portManagerStampsUnhealthyPortFromHPMData() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(
                uuid: "6230AF2D-EE59-552E-E28A-652CCC0E7B11",
                portNumber: 1,
                portType: "USB-C",
                overcurrentCount: 2,
                plugEventCount: 5,
                connectionCount: 10,
                authorizationStatus: "Authorized",
                ldcmStatus: "No Error"
            )
        ],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)]
    )

    manager.applySnapshot(snapshot)

    let port = manager.ports.first { $0.id == 1 }
    #expect(port?.health != nil)
    #expect(port?.health?.overcurrentCount == 2)
    #expect(port?.health?.isHealthy == false)
}

// HPM provisioned/blocked transports and CIO tunnelled transports both land
// on PortState.transports. The blocked USB3 is the "why doesn't my dock work"
// signal, and the tunnelled list shows what is riding the TB link.
@Test func portManagerSurfacesProvisionedAndBlockedTransports() {
    let manager = PortManager()
    let uuid = "6230AF2D-EE59-552E-E28A-652CCC0E7B11"

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(
                uuid: uuid, portNumber: 1, portType: "USB-C",
                provisionedTransports: ["CC", "USB2", "DP"],
                unauthorizedTransports: ["USB3"]
            )
        ],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        cioTransport: [
            CIOTransportInput(
                portNumber: 1, active: true,
                tunnelProvisioned: ["DisplayPort", "PCIe"]
            )
        ]
    )

    manager.applySnapshot(snapshot)
    let port = manager.ports.first { $0.id == 1 }

    #expect(port?.transports?.provisioned == ["CC", "USB2", "DP"])
    #expect(port?.transports?.unauthorized == ["USB3"])
    #expect(port?.transports?.tunnelProvisioned == ["DisplayPort", "PCIe"])
    #expect(port?.transports?.hasData == true)
}

// With no HPM transport lists and no CIO tunnel data, transports stays nil
// (pre-M3 / Intel / desktop) rather than an empty-but-present struct.
@Test func portManagerLeavesTransportsNilWithoutData() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)]
    )

    manager.applySnapshot(snapshot)
    #expect(manager.ports.first { $0.id == 1 }?.transports == nil)
}

// Liquid detection is the most serious health signal: it makes the port
// unhealthy regardless of counters.
@Test func portManagerFlagsLiquidDetectionAsSerious() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(
                uuid: "6230AF2D-EE59-552E-E28A-652CCC0E7B11",
                portNumber: 1, portType: "USB-C",
                ldcmStatus: "No Error",
                liquidDetected: true,
                mitigationsActive: true
            )
        ],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)]
    )

    manager.applySnapshot(snapshot)
    let port = manager.ports.first { $0.id == 1 }

    #expect(port?.health?.liquidDetected == true)
    #expect(port?.health?.mitigationsActive == true)
    #expect(port?.health?.severity == .serious)
    #expect(port?.health?.isHealthy == false)
}

// DisplayPort link detail (lanes, sink count, branch chip, downstream type)
// flows from the DP transport into the port's LiveTransport entry.
@Test func portManagerCarriesDisplayLinkDetail() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1, lane0Transport: "DisplayPort", lane0PowerLevel: "on")],
        tbData: [ThunderboltInput(socketID: 1)],
        dpTransport: [
            DPTransportInput(
                portNumber: 1, active: true, linkRate: "5.4 Gbps (HBR2)",
                laneCount: 2, maxLaneCount: 4, tunneled: false,
                sinkCount: 2, branchDevice: "Dp1.2", dfpType: "HDMI"
            )
        ]
    )

    manager.applySnapshot(snapshot)
    let dp = manager.ports.first { $0.id == 1 }?.liveTransports.first { $0.kind == .displayPort }

    #expect(dp?.laneCount == 2)
    #expect(dp?.maxLaneCount == 4)
    #expect(dp?.sinkCount == 2)
    #expect(dp?.branchDevice == "Dp1.2")
    #expect(dp?.dfpType == "HDMI")
}

// The USB3 generation label ("Gen 2") round-trips from USB3TransportInput
// alongside the data rate, into the port's LiveTransport entry.
@Test func portManagerCarriesUSB3Generation() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1, lane0Transport: "USB3", lane0PowerLevel: "on")],
        tbData: [ThunderboltInput(socketID: 1)],
        usb3Transport: [
            USB3TransportInput(portNumber: 1, active: true, dataRate: "10 Gbps", generation: "Gen 2")
        ]
    )

    manager.applySnapshot(snapshot)
    let usb3 = manager.ports.first { $0.id == 1 }?.liveTransports.first { $0.kind == .usb }

    #expect(usb3?.dataRate == "10 Gbps")
    #expect(usb3?.generation == "Gen 2")
}

// bDeviceClass decodes onto USBDeviceInfo.deviceClass through the
// correlation path, and a per-interface/unmapped class (0x00) stays nil.
@Test func portManagerDecodesDeviceClass() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        deviceData: [DeviceInput(portNumber: 1, productName: "Hub", deviceClass: 0x09)]
    )

    manager.applySnapshot(snapshot)
    #expect(manager.ports.first { $0.id == 1 }?.usbDevice?.deviceClass == .hub)
    // Single-device port regression: one device in, one device out.
    #expect(manager.ports.first { $0.id == 1 }?.usbDevices.count == 1)

    let unmappedSnapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        deviceData: [DeviceInput(portNumber: 1, productName: "Mystery Device", deviceClass: 0x00)]
    )

    manager.applySnapshot(unmappedSnapshot)
    #expect(manager.ports.first { $0.id == 1 }?.usbDevice?.deviceClass == nil)
    #expect(manager.ports.first { $0.id == 1 }?.usbDevices.count == 1)
}

// Corpus fixture (m4max_macos26.5.1_f, also used in DeviceTreeTests): two
// nested "USB2.0 Hub" devices with a PreSonus "ATOM" behind the inner one.
// The whole chain must come back as one pre-order tree, and the free tier
// must front ATOM (the real device), not either hub.
@Test func portManagerBuildsMultiDeviceTreeInPreOrder() {
    let manager = PortManager()

    let outerHub = DeviceInput(portNumber: 1, productName: "USB2.0 Hub", deviceClass: 0x09, locationID: 0x3100000)
    let innerHub = DeviceInput(portNumber: 1, productName: "USB2.0 Hub", deviceClass: 0x09, locationID: 0x3140000)
    let atom = DeviceInput(portNumber: 1, productName: "ATOM", locationID: 0x3141000)

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        deviceData: [outerHub, innerHub, atom]
    )

    manager.applySnapshot(snapshot)
    let port = manager.ports.first { $0.id == 1 }

    #expect(port?.usbDevices.count == 3)
    #expect(port?.usbDevices.map(\.productName) == ["USB2.0 Hub", "USB2.0 Hub", "ATOM"])

    let atomInfo = port?.usbDevices.last
    #expect(atomInfo?.hubDepth == 2)
    #expect(atomInfo?.viaName == "USB2.0 Hub")

    #expect(port?.usbDevice?.productName == "ATOM")
    #expect(port?.additionalDeviceCount == 0)
}

// The free tier fronts the first real device in tree order regardless of
// where the hub sits in the enumeration order.
@Test func portManagerPrimarySelectionPrefersNonHubRegardlessOfOrder() {
    let hubFirst = PortManager()
    hubFirst.applySnapshot(
        PortManagerSnapshot(
            phyData: [PhyInput(phyID: 0, portNumber: 1)],
            tbData: [ThunderboltInput(socketID: 1)],
            deviceData: [
                DeviceInput(portNumber: 1, productName: "Hub", deviceClass: 0x09, locationID: 0x1100000),
                DeviceInput(portNumber: 1, productName: "Keyboard", locationID: 0x1110000)
            ]
        )
    )
    #expect(hubFirst.ports.first { $0.id == 1 }?.usbDevice?.productName == "Keyboard")

    let hubSecond = PortManager()
    hubSecond.applySnapshot(
        PortManagerSnapshot(
            phyData: [PhyInput(phyID: 0, portNumber: 1)],
            tbData: [ThunderboltInput(socketID: 1)],
            deviceData: [
                DeviceInput(portNumber: 1, productName: "Keyboard", locationID: 0x1110000),
                DeviceInput(portNumber: 1, productName: "Hub", deviceClass: 0x09, locationID: 0x1100000)
            ]
        )
    )
    #expect(hubSecond.ports.first { $0.id == 1 }?.usbDevice?.productName == "Keyboard")
}

// A port with only hubs attached (nothing real behind them) still fronts
// the first hub rather than going nil, and "+N more" stays at zero since
// hubs are plumbing, not something the user plugged in.
@Test func portManagerHubOnlyPortFrontsFirstHub() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        deviceData: [
            DeviceInput(portNumber: 1, productName: "Outer Hub", deviceClass: 0x09, locationID: 0x1100000),
            DeviceInput(portNumber: 1, productName: "Inner Hub", deviceClass: 0x09, locationID: 0x1110000)
        ]
    )

    manager.applySnapshot(snapshot)
    let port = manager.ports.first { $0.id == 1 }

    #expect(port?.usbDevice != nil)
    #expect(port?.usbDevice?.productName == "Outer Hub")
    #expect(port?.additionalDeviceCount == 0)
}

// A hub with two real devices behind it plus the fronted one: "+N more"
// counts the real devices beyond the one already shown, not the hub.
@Test func portManagerAdditionalDeviceCountExcludesHubs() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        deviceData: [
            DeviceInput(portNumber: 1, productName: "Hub", deviceClass: 0x09, locationID: 0x1100000),
            DeviceInput(portNumber: 1, productName: "Mouse", locationID: 0x1110000),
            DeviceInput(portNumber: 1, productName: "Keyboard", locationID: 0x1120000),
            DeviceInput(portNumber: 1, productName: "Webcam", locationID: 0x1130000)
        ]
    )

    manager.applySnapshot(snapshot)
    let port = manager.ports.first { $0.id == 1 }

    #expect(port?.usbDevice?.productName == "Mouse")
    #expect(port?.additionalDeviceCount == 2)
}

// A port can have two devices attached directly (two independent roots,
// no shared hub). Both subtrees must come back, each in pre-order, and the
// roots keep the order they were enumerated in.
@Test func portManagerHandlesTwoIndependentRoots() {
    let manager = PortManager()

    let firstRoot = DeviceInput(portNumber: 1, productName: "Dock A", deviceClass: 0x09, locationID: 0x1100000)
    let firstChild = DeviceInput(portNumber: 1, productName: "Dock A Bay", locationID: 0x1110000)
    let secondRoot = DeviceInput(portNumber: 1, productName: "Dock B", deviceClass: 0x09, locationID: 0x1200000)
    let secondChild = DeviceInput(portNumber: 1, productName: "Dock B Bay", locationID: 0x1210000)

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        deviceData: [firstRoot, firstChild, secondRoot, secondChild]
    )

    manager.applySnapshot(snapshot)
    let names = manager.ports.first { $0.id == 1 }?.usbDevices.map(\.productName)

    #expect(names == ["Dock A", "Dock A Bay", "Dock B", "Dock B Bay"])
}

// Two ports whose devices happen to share overlapping locationIDs (a real
// possibility since locationID is only unique within a bus) must not bleed
// into each other's tree. buildDeviceTree operates on each port's own
// slice, never the whole deviceData array.
@Test func portManagerIsolatesDeviceTreesAcrossPorts() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [
            PhyInput(phyID: 0, portNumber: 1),
            PhyInput(phyID: 1, portNumber: 2)
        ],
        tbData: [
            ThunderboltInput(socketID: 1),
            ThunderboltInput(socketID: 2)
        ],
        deviceData: [
            DeviceInput(portNumber: 1, productName: "Port 1 Hub", deviceClass: 0x09, locationID: 0x1100000),
            DeviceInput(portNumber: 1, productName: "Port 1 Device", locationID: 0x1110000),
            DeviceInput(portNumber: 2, productName: "Port 2 Hub", deviceClass: 0x09, locationID: 0x1100000),
            DeviceInput(portNumber: 2, productName: "Port 2 Device", locationID: 0x1110000)
        ]
    )

    manager.applySnapshot(snapshot)
    let port1Names = manager.ports.first { $0.id == 1 }?.usbDevices.map(\.productName)
    let port2Names = manager.ports.first { $0.id == 2 }?.usbDevices.map(\.productName)

    #expect(port1Names == ["Port 1 Hub", "Port 1 Device"])
    #expect(port2Names == ["Port 2 Hub", "Port 2 Device"])
}

// Two devices reporting the same locationID as roots (a real registry
// anomaly, since locationID collisions do happen) plus one child of that
// shared location. Each device must still be emitted exactly once, and since
// both roots compete for the same child, the child attaches to whichever
// root visits it first in enumeration order, never doubling up.
@Test func portManagerPinsChildToFirstRootWhenLocationIDsCollide() {
    let manager = PortManager()

    let firstRoot = DeviceInput(portNumber: 1, productName: "Root A", deviceClass: 0x09, locationID: 0x1100000)
    let secondRoot = DeviceInput(portNumber: 1, productName: "Root B", deviceClass: 0x09, locationID: 0x1100000)
    let child = DeviceInput(portNumber: 1, productName: "Child", locationID: 0x1110000)

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        deviceData: [firstRoot, secondRoot, child]
    )

    manager.applySnapshot(snapshot)
    let names = manager.ports.first { $0.id == 1 }?.usbDevices.map(\.productName)

    #expect(names == ["Root A", "Child", "Root B"])
    #expect(names?.count == 3)
}

// DP tunnel link rate (from PHY tunnel data) flows onto PortState even when
// no live DP transport node is present, so the UI has a fallback to show.
@Test func portManagerCarriesDPTunnelLinkRate() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1, dpTunnel: "5.40Gbps/lane (HBR2)")],
        tbData: [ThunderboltInput(socketID: 1)]
    )

    manager.applySnapshot(snapshot)
    let port = manager.ports.first { $0.id == 1 }

    #expect(port?.dpTunnelLinkRate == "5.40Gbps/lane (HBR2)")
}

// The connected Thunderbolt device's identity (from the CIO node) is stamped
// onto the active TB link.
@Test func portManagerNamesConnectedThunderboltDevice() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1, lane0Transport: "CIO", lane0PowerLevel: "on")],
        tbData: [ThunderboltInput(socketID: 1, currentLinkWidth: 2, currentLinkSpeed: 4)],
        cioTransport: [
            CIOTransportInput(portNumber: 1, active: true, deviceModel: "TS3 Plus", deviceVendor: "CalDigit")
        ]
    )

    manager.applySnapshot(snapshot)
    let port = manager.ports.first { $0.id == 1 }

    #expect(port?.thunderboltLink?.deviceName == "TS3 Plus")
    #expect(port?.thunderboltLink?.deviceVendor == "CalDigit")
}

// The active charger's identity is attached to the port receiving power.
@Test func portManagerAttachesChargerIdentityToIncomingPort() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        ccData: [CCInput(portNumber: 1, portType: "USB-C", active: true)],
        chargerData: [ChargerInput(portType: "USB-C", portNumber: 1, maxWatts: 100000, voltage: 20000, maxCurrent: 5000, hasWinningContract: true)],
        chargingPower: ChargingPowerInput(systemPowerIn: 60000, systemVoltageIn: 20000,
                                          systemCurrentIn: 3000, isCharging: true),
        chargerIdentity: ChargerIdentityInput(
            name: "96W USB-C Power Adapter", manufacturer: "Apple Inc.", maxWatts: 96,
            pdos: [ChargerPDO(voltageMV: 5000, currentMA: 3000), ChargerPDO(voltageMV: 20000, currentMA: 4700)]
        )
    )

    manager.applySnapshot(snapshot)
    let port = manager.ports.first { $0.id == 1 }

    #expect(port?.power?.direction == .incoming)
    #expect(port?.charger?.name == "96W USB-C Power Adapter")
    #expect(port?.charger?.isApple == true)
    #expect(port?.charger?.maxWatts == 96)
    #expect(port?.charger?.pdos.count == 2)
}

// Charger identity is only attached where power is flowing in: a port with no
// incoming power (or a desktop with no battery) stays nil.
@Test func portManagerDoesNotAttachChargerWithoutIncomingPower() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        chargerIdentity: ChargerIdentityInput(name: "PD charger")
    )

    manager.applySnapshot(snapshot)
    #expect(manager.ports.first { $0.id == 1 }?.charger == nil)
}

// A third-party charger reporting only a description still resolves to a
// usable name rather than an empty string.
@Test func chargerIdentityFallsBackToDescription() {
    let input = ChargerIdentityInput(name: "", description: "pd charger")
    #expect(input.resolvedName == "pd charger")
    #expect(input.toChargerInfo().name == "pd charger")
    #expect(input.toChargerInfo().isApple == false)
}

// ChargingStatus is derived from reliable battery fields plus the two verified
// NotChargingReason bits. Values are real ones observed in the WhatCable corpus.
@Test func chargingStatusClassifiesFromVerifiedFields() {
    // Actively charging wins over everything.
    #expect(ChargingStatus(isCharging: true, fullyCharged: false, notChargingReason: 0) == .charging)
    #expect(ChargingStatus(isCharging: true, fullyCharged: true, notChargingReason: 0) == .charging)
    // Full (the value 4194305 carries bit22, but the bool is authoritative).
    #expect(ChargingStatus(isCharging: false, fullyCharged: true, notChargingReason: 4194305) == .fullyCharged)
    // bit24 (16777216) and bit55 both mean a deliberate battery-health hold.
    #expect(ChargingStatus(isCharging: false, fullyCharged: false, notChargingReason: 16777216) == .onHoldForHealth)
    #expect(ChargingStatus(isCharging: false, fullyCharged: false, notChargingReason: 36028797018963968) == .onHoldForHealth)
    // An undecoded reason (bit7 = 128) reports generically, never a guess.
    #expect(ChargingStatus(isCharging: false, fullyCharged: false, notChargingReason: 128) == .notCharging)
    #expect(ChargingStatus(isCharging: false, fullyCharged: false, notChargingReason: 0) == .notCharging)
}

// The manager exposes chargingStatus only when a charger is connected
// (chargingPower non-nil); on battery / no battery it stays nil.
@Test func portManagerExposesChargingStatus() {
    let manager = PortManager()

    manager.applySnapshot(PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        chargingPower: ChargingPowerInput(systemPowerIn: 0, systemVoltageIn: 0, systemCurrentIn: 0,
                                          isCharging: false, fullyCharged: false,
                                          notChargingReason: 16777216)
    ))
    #expect(manager.chargingStatus == .onHoldForHealth)

    // No chargingPower -> nil (on battery / desktop).
    manager.applySnapshot(PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)]
    ))
    #expect(manager.chargingStatus == nil)
}

// systemWallPowerWatts is set straight from the snapshot, like isCharging and
// chargingStatus -- it is not a per-port figure, so correlate() must never
// touch it, and it must survive a snapshot with no ports at all (a desktop
// mid-scan).
@Test func portManagerSetsSystemWallPowerFromSnapshot() {
    let manager = PortManager()

    manager.applySnapshot(PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        systemPower: SystemPowerInput(watts: 142.0, volts: 20.0, amps: 7.1)
    ))

    #expect(manager.systemWallPowerWatts == 142.0)
    // Untouched by correlate(): the port itself carries no power reading.
    #expect(manager.ports.first?.power == nil)

    // No systemPower on the snapshot -> nil, not a stale carry-over.
    manager.applySnapshot(PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)]
    ))
    #expect(manager.systemWallPowerWatts == nil)
}

// controllerPower is set straight from the snapshot, like systemWallPowerWatts:
// it is machine-wide, not per-port, so correlate() must never touch it. This
// is reader-only plumbing for a future feature; nothing consumes the value
// yet, so this only pins that it survives the round trip through applySnapshot.
@Test func portManagerStoresControllerPowerFromSnapshot() {
    let manager = PortManager()

    manager.applySnapshot(PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        controllerPower: ControllerPowerInput(
            anyThunderboltControllerAwake: true,
            anyXHCIControllerAwake: false,
            thunderboltControllerCount: 2,
            xhciControllerCount: 1
        )
    ))

    #expect(manager.controllerPower?.anyThunderboltControllerAwake == true)
    #expect(manager.controllerPower?.anyXHCIControllerAwake == false)
    #expect(manager.controllerPower?.thunderboltControllerCount == 2)
    #expect(manager.controllerPower?.xhciControllerCount == 1)
    // Untouched by correlate(): the port itself carries no controller data.
    #expect(manager.ports.first?.power == nil)

    // No controllerPower on the snapshot -> nil, not a stale carry-over.
    manager.applySnapshot(PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)]
    ))
    #expect(manager.controllerPower == nil)
}

// Without HPM data (Intel / desktop / tests), ports still correlate by number
// and simply carry no UUID. Confirms the legacy fallback path is intact.
@Test func portManagerCorrelatesWithoutHPMData() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        ccData: [CCInput(portNumber: 1, portType: "USB-C", active: true)]
    )

    manager.applySnapshot(snapshot)

    #expect(manager.ports.count == 1)
    #expect(manager.ports[0].id == 1)
    #expect(manager.ports[0].uuid == nil)
}

// MARK: - PD reliability counters (DAR-289)

// The join is ordinal, not positional-by-port-number: PDReliabilityInput's
// entryOffset is PortControllerInfo's own 0-based array offset, and it maps
// to the (i+1)-th USB-C port when the machine's USB-C ports are sorted
// ascending by physical port number. On contiguous port numbering (1, 2,
// ...) that lands identically to the old offset+1 == portNumber rule.
@Test func portManagerJoinsPDReliabilityOrdinallyOnContiguousPorts() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: "AAAA", portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: "BBBB", portNumber: 2, portType: "USB-C"),
        ],
        phyData: [
            PhyInput(phyID: 0, portNumber: 1),
            PhyInput(phyID: 1, portNumber: 2),
        ],
        tbData: [
            ThunderboltInput(socketID: 1),
            ThunderboltInput(socketID: 2),
        ],
        pdReliabilityData: [
            PDReliabilityInput(entryOffset: 0, attachCount: 3, detachCount: 2, hardResetCount: 1),
            PDReliabilityInput(entryOffset: 1, attachCount: 7, detachCount: 6, i2cErrorCount: 4),
        ]
    )

    manager.applySnapshot(snapshot)

    let port1 = manager.ports.first { $0.id == 1 }
    let port2 = manager.ports.first { $0.id == 2 }

    #expect(port1?.pdReliability?.attachCount == 3)
    #expect(port1?.pdReliability?.detachCount == 2)
    #expect(port1?.pdReliability?.hardResetCount == 1)
    #expect(port2?.pdReliability?.attachCount == 7)
    #expect(port2?.pdReliability?.i2cErrorCount == 4)
}

// The non-contiguous case the ordinal rule exists for (e.g. M5 MacBook Pro:
// USB-C ports {1, 2, 4}). Entry offset 0/1/2 must land on ports 1/2/4 in that
// order, and a trailing 4th entry (the MagSafe controller) must land nowhere.
@Test func portManagerJoinsPDReliabilityOrdinallyOnNonContiguousPorts() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: "AAAA", portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: "BBBB", portNumber: 2, portType: "USB-C"),
            HPMPortInput(uuid: "CCCC", portNumber: 4, portType: "USB-C"),
        ],
        phyData: [
            PhyInput(phyID: 0, portNumber: 1),
            PhyInput(phyID: 1, portNumber: 2),
            PhyInput(phyID: 2, portNumber: 4),
        ],
        tbData: [
            ThunderboltInput(socketID: 1),
            ThunderboltInput(socketID: 2),
            ThunderboltInput(socketID: 4),
        ],
        pdReliabilityData: [
            PDReliabilityInput(entryOffset: 0, attachCount: 3),
            PDReliabilityInput(entryOffset: 1, attachCount: 7),
            PDReliabilityInput(entryOffset: 2, attachCount: 11),
            // The extra 4th entry: the MagSafe controller. Never a USB-C port.
            PDReliabilityInput(entryOffset: 3, attachCount: 99),
        ]
    )

    manager.applySnapshot(snapshot)

    let port1 = manager.ports.first { $0.id == 1 }
    let port2 = manager.ports.first { $0.id == 2 }
    let port4 = manager.ports.first { $0.id == 4 }

    #expect(port1?.pdReliability?.attachCount == 3)
    #expect(port2?.pdReliability?.attachCount == 7)
    #expect(port4?.pdReliability?.attachCount == 11)

    // The trailing entry (offset 3, the MagSafe controller) never attaches
    // anywhere: only offsets 0..<usbCCount are ever consumed.
    #expect(!manager.ports.contains { $0.pdReliability?.attachCount == 99 })
}

// An entry count that is neither the USB-C port count nor that count + 1
// breaks the invariant the ordinal rule depends on, so the join fails
// closed: nothing attaches to any port rather than guessing.
@Test func portManagerFailsClosedOnUnexpectedPDReliabilityEntryCount() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: "AAAA", portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: "BBBB", portNumber: 2, portType: "USB-C"),
        ],
        phyData: [
            PhyInput(phyID: 0, portNumber: 1),
            PhyInput(phyID: 1, portNumber: 2),
        ],
        tbData: [
            ThunderboltInput(socketID: 1),
            ThunderboltInput(socketID: 2),
        ],
        // 2 USB-C ports: a valid count would be 2 or 3. 4 matches neither.
        pdReliabilityData: [
            PDReliabilityInput(entryOffset: 0, attachCount: 3),
            PDReliabilityInput(entryOffset: 1, attachCount: 7),
            PDReliabilityInput(entryOffset: 2, attachCount: 11),
            PDReliabilityInput(entryOffset: 3, attachCount: 99),
        ]
    )

    manager.applySnapshot(snapshot)

    #expect(manager.ports.allSatisfy { $0.pdReliability == nil })
}

// MagSafe never receives an ordinal PortControllerInfo entry: even when a PD
// reliability entry's offset would collide with MagSafe's own port number
// (the same "@N" collision USB-C and MagSafe already share elsewhere), only
// the USB-C port at that ordinal position may receive it.
@Test func portManagerNeverAttachesPDReliabilityToMagSafe() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [
            HPMPortInput(uuid: "AAAA", portNumber: 1, portType: "USB-C"),
            HPMPortInput(uuid: "MMMM", portNumber: 1, portType: "MagSafe 3"),
        ],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)],
        ccData: [CCInput(portNumber: 1, portType: "MagSafe 3", active: true)],
        pdReliabilityData: [
            PDReliabilityInput(entryOffset: 0, attachCount: 5),
        ]
    )

    manager.applySnapshot(snapshot)

    let usbcPort = manager.ports.first { $0.portType == .usbC }
    let magSafePort = manager.ports.first { $0.portType == .magSafe }

    #expect(usbcPort?.pdReliability?.attachCount == 5)
    #expect(magSafePort?.pdReliability == nil)
}

// No pdReliabilityData on the snapshot at all (e.g. a desktop with no
// PortControllerInfo array) leaves every port's pdReliability nil.
@Test func portManagerLeavesPDReliabilityNilWithoutData() {
    let manager = PortManager()

    let snapshot = PortManagerSnapshot(
        hpmPorts: [HPMPortInput(uuid: "AAAA", portNumber: 1, portType: "USB-C")],
        phyData: [PhyInput(phyID: 0, portNumber: 1)],
        tbData: [ThunderboltInput(socketID: 1)]
    )

    manager.applySnapshot(snapshot)

    #expect(manager.ports.first?.pdReliability == nil)
}
