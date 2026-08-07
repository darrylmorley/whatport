import WhatPortCore
import WhatPortIOKit

// Converts IOKit's raw PortSnapshot into the domain layer's PortManagerSnapshot.
// This adapter sits in the app target because it bridges the two library targets.
// Neither library imports the other directly.
enum SnapshotAdapter {
    static func convert(_ snapshot: PortSnapshot) -> PortManagerSnapshot {
        PortManagerSnapshot(
            timestamp: snapshot.timestamp,
            hpmPorts: snapshot.hpmPorts.map { hpm in
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
            },
            phyData: snapshot.phyData.map { phy in
                PhyInput(
                    phyID: phy.phyID,
                    portNumber: phy.portNumber,
                    lane0Transport: phy.lane0Transport,
                    lane0PowerLevel: phy.lane0PowerLevel,
                    lane0Client: phy.lane0Client,
                    lane1Transport: phy.lane1Transport,
                    lane1PowerLevel: phy.lane1PowerLevel,
                    lane1Client: phy.lane1Client,
                    usb2Transport: phy.usb2Transport,
                    dpLinkRate: phy.dpLinkRate,
                    dpTunnel: phy.dpTunnel
                )
            },
            tbData: snapshot.thunderboltData.compactMap { tb in
                guard let socketID = Int(tb.socketID) else { return nil }
                return ThunderboltInput(
                    socketID: socketID,
                    currentLinkWidth: tb.currentLinkWidth,
                    currentLinkSpeed: tb.currentLinkSpeed,
                    supportedLinkWidth: tb.supportedLinkWidth,
                    supportedLinkSpeed: tb.supportedLinkSpeed,
                    thunderboltVersion: tb.thunderboltVersion,
                    dualLinkPort: tb.dualLinkPort
                )
            },
            powerData: snapshot.powerData.map { pwr in
                PowerInput(
                    portIndex: pwr.portIndex,
                    watts: pwr.watts,
                    current: pwr.current,
                    adapterVoltage: pwr.adapterVoltage,
                    configuredVoltage: pwr.configuredVoltage,
                    configuredCurrent: pwr.configuredCurrent,
                    vconnCurrent: pwr.vconnCurrent,
                    vconnPower: pwr.vconnPower,
                    vconnMaxCurrent: pwr.vconnMaxCurrent
                )
            },
            ccData: snapshot.ccData.map { cc in
                CCInput(
                    portNumber: cc.portNumber,
                    portType: cc.portType,
                    active: cc.active,
                    cableProductType: cc.cableProductType,
                    cablePDRevision: cc.cablePDRevision
                )
            },
            chargerData: snapshot.chargerData.map { $0.toChargerInput() },
            chargingPower: snapshot.chargingPower.map { cp in
                ChargingPowerInput(
                    systemPowerIn: cp.systemPowerIn,
                    systemVoltageIn: cp.systemVoltageIn,
                    systemCurrentIn: cp.systemCurrentIn,
                    isCharging: cp.isCharging,
                    fullyCharged: cp.fullyCharged,
                    notChargingReason: cp.notChargingReason
                )
            },
            chargerIdentity: snapshot.chargerIdentity.map { ci in
                ChargerIdentityInput(
                    name: ci.name,
                    manufacturer: ci.manufacturer,
                    description: ci.description,
                    maxWatts: ci.maxWatts,
                    pdos: ci.pdos.map { ChargerPDO(voltageMV: $0.voltageMV, currentMA: $0.currentMA) }
                )
            },
            deviceData: snapshot.deviceData.map { d in
                DeviceInput(
                    portNumber: d.portNumber,
                    productName: d.productName,
                    vendorName: d.vendorName,
                    speedCode: d.speedCode,
                    usbVersion: d.usbVersion,
                    deviceClass: d.deviceClass,
                    currentDraw: d.currentDraw,
                    serialNumber: d.serialNumber,
                    locationID: d.locationID
                )
            },
            displayData: snapshot.displayData.map { d in
                DisplayInput(
                    portNumber: d.portNumber,
                    productName: d.productName,
                    maxWidth: d.maxWidth,
                    maxHeight: d.maxHeight
                )
            },
            portStatsData: snapshot.portStatsData.map { s in
                PortStatsInput(
                    portNumber: s.portNumber,
                    connectCount: s.connectCount,
                    overcurrentCount: s.overcurrentCount,
                    enumerationFailureCount: s.enumerationFailureCount,
                    addressFailureCount: s.addressFailureCount,
                    linkErrorCount: s.linkErrorCount,
                    remoteWakeCount: s.remoteWakeCount
                )
            },
            powerMeteringAvailable: snapshot.powerMeteringAvailable,
            usb3Transport: snapshot.usb3Transport.map { t in
                USB3TransportInput(
                    portNumber: t.portNumber,
                    active: t.active,
                    dataRate: t.dataRate,
                    generation: t.generation,
                    generationFamily: t.generationFamily,
                    tunneled: t.tunneled,
                    transportRestricted: t.transportRestricted
                )
            },
            dpTransport: snapshot.dpTransport.map { t in
                DPTransportInput(
                    portNumber: t.portNumber,
                    active: t.active,
                    linkRate: t.linkRate,
                    laneCount: t.laneCount,
                    maxLaneCount: t.maxLaneCount,
                    tunneled: t.tunneled,
                    sinkCount: t.sinkCount,
                    branchDevice: t.branchDevice,
                    dfpType: t.dfpType
                )
            },
            cioTransport: snapshot.cioTransport.map { t in
                CIOTransportInput(
                    portNumber: t.portNumber,
                    active: t.active,
                    dataRate: t.dataRate,
                    tunneled: t.tunneled,
                    tunnelProvisioned: t.tunnelProvisioned,
                    tunnelSupported: t.tunnelSupported,
                    deviceModel: t.deviceModel,
                    deviceVendor: t.deviceVendor
                )
            },
            smcPortPower: snapshot.smcPortPower.map { s in
                SMCPortPowerInput(
                    present: s.present,
                    volts: s.volts,
                    amps: s.amps,
                    uuid: s.uuid
                )
            },
            smcPortContracts: snapshot.smcPortContracts.map { c in
                SMCPortContractInput(
                    channel: c.channel,
                    uuid: c.uuid,
                    powerMW: c.powerMW,
                    voltageMV: c.voltageMV,
                    currentMA: c.currentMA,
                    label: c.label
                )
            },
            systemPower: snapshot.smcSystemPower.map { sp in
                SystemPowerInput(watts: sp.watts, volts: sp.volts, amps: sp.amps)
            },
            controllerPower: snapshot.controllerPower.map { cp in
                ControllerPowerInput(
                    anyThunderboltControllerAwake: cp.anyThunderboltControllerAwake,
                    anyXHCIControllerAwake: cp.anyXHCIControllerAwake,
                    thunderboltControllerCount: cp.thunderboltControllerCount,
                    xhciControllerCount: cp.xhciControllerCount
                )
            }
        )
    }

    // Converts IOKit's raw lifecycle event into the domain layer's lifecycle
    // signal input. MagSafe ports use id = 100 + portNumber, the same
    // convention PortManager applies when building non-USB-C ports from CC
    // data (see buildNonUSBCPorts). PortManager keeps that offset as a plain
    // literal rather than a shared constant, so this mirrors it the same way.
    static func convert(_ event: RawPortLifecycleEvent) -> PortLifecycleSignalInput {
        let portID = event.isMagSafe ? 100 + event.portNumber : event.portNumber

        let signal: LifecycleSignalKind
        switch event.signal {
        case .attach:
            signal = .attach
        case .negotiating:
            signal = .negotiating
        case .contractEstablished:
            signal = .contractEstablished
        case .transportReady:
            signal = .transportReady
        }

        return PortLifecycleSignalInput(portID: portID, signal: signal)
    }
}
